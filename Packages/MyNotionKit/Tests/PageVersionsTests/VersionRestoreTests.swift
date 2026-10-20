import Foundation
import Testing
@testable import NotesCore
@testable import PageVersions
@testable import Sync

/// Восстановление версии (contracts/page-operations.md, «История версий»; research R11) — сценарии потери данных:
/// поля и блоки как в версии; удалённые с тех пор — с прежними id; копии с `movedFrom` на других страницах удалены;
/// снимок «до восстановления» и новая версия после; ⌘Z — как было; правки уходят в исходящие синхронизации.
@MainActor
@Suite("Версии: восстановление")
struct VersionRestoreTests {
    /// Версия страницы «как сейчас» (снимок по запросу).
    private func versionNow(_ mac: VersionsTestMac, _ pageId: UUID) throws -> PageVersionInfo {
        mac.clock.advance(by: 61)
        return try #require(try mac.recorder.recordPending(pageId) ?? mac.versionList(pageId).first)
    }

    private func restorer(_ mac: VersionsTestMac) -> VersionRestorer {
        VersionRestorer(recorder: mac.recorder, versions: mac.versions, operations: mac.tree)
    }

    /// «Переместить в»: копии с `movedFrom` в конец страницы-цели, исходные удалены, подстраницы ссылок переехали.
    private func moveBlocks(_ ids: [UUID], from source: UUID, to target: UUID, _ mac: VersionsTestMac) throws {
        try mac.store.write { tx in
            let blocks = try tx.blocks(ofPage: source)
            let roots = blocks.filter { ids.contains($0.id) }
            let copy = BlockCopier.copy(roots, pageBlocks: blocks, into: target, after: try tx.blocks(ofPage: target).last?.sortKey,
                                        marksMovedFrom: true)
            for original in copy.originals.reversed() { try tx.deleteBlock(original.id) }
            for block in copy.blocks {
                try tx.insertBlock(block)
                if let linked = block.linkedPageId, var subpage = try tx.page(linked), subpage.parentId == source {
                    subpage.parentId = target
                    try tx.updatePage(subpage)
                }
            }
        }
    }

    @Test("Поля страницы и блоки — как в версии; блоки с прежними id")
    func fieldsAndBlocksAsInVersion() throws {
        let mac = try VersionsTestMac()
        mac.recorder.start()
        let page = try mac.page("Было", texts: ["один", "два", "три"])
        let before = try mac.blocks(page.id)
        let version = try versionNow(mac, page.id)
        try mac.updatePage(page.id) {
            $0.title = "Стало"
            $0.icon = "🔥"
            $0.cover = PageCover(source: .gallery("solid_red"))
            $0.isFullWidth = true
            $0.isSmallText = true
        }
        try mac.setText("один — правка", ofBlock: before[0].id)
        try mac.store.write { tx in
            try tx.deleteBlock(before[1].id)
            try tx.insertBlock(Block(pageId: page.id, text: InlineText("лишний"), sortKey: .between(before[2].sortKey, nil)))
        }
        try restorer(mac).restore(versionId: version.id, ofPage: page.id)
        let restored = try #require(try mac.store.pageContent(page.id))
        #expect(restored.page.title == "Было")
        #expect(restored.page.icon == nil && restored.page.cover == nil)
        #expect(!restored.page.isFullWidth && !restored.page.isSmallText)
        #expect(restored.blocks.map(\.id) == before.map(\.id))
        #expect(restored.blocks.map(\.text.string) == ["один", "два", "три"])
    }

    @Test("Удалённые с тех пор блоки возвращаются с прежними id — и с пометками синхронизации, и без")
    func deletedBlocksReturn() throws {
        for syncs in [false, true] {
            let mac = try VersionsTestMac(syncs: syncs)
            mac.store.keepsDeletionMarks = syncs
            let page = try mac.page("Удаления", texts: ["а", "б", "в"])
            let blocks = try mac.blocks(page.id)
            let version = try versionNow(mac, page.id)
            try mac.store.write { tx in for block in blocks { try tx.deleteBlock(block.id) } }
            #expect(try mac.texts(page.id) == [""], "Страница без блоков получает пустой абзац")
            try restorer(mac).restore(versionId: version.id, ofPage: page.id)
            #expect(try mac.blocks(page.id).map(\.id) == blocks.map(\.id), "синхронизация: \(syncs)")
            #expect(try mac.texts(page.id) == ["а", "б", "в"])
        }
    }

    @Test("Блоки, унесённые «Переместить в» на другую страницу, возвращаются; копии там удалены")
    func movedBlocksReturn() throws {
        let mac = try VersionsTestMac()
        let source = try mac.page("Откуда", texts: ["остаётся", "уедет 1", "уедет 2"])
        let target = try mac.page("Куда", texts: ["своё"])
        let blocks = try mac.blocks(source.id)
        let version = try versionNow(mac, source.id)
        try moveBlocks([blocks[1].id, blocks[2].id], from: source.id, to: target.id, mac)
        #expect(try mac.texts(target.id) == ["своё", "уедет 1", "уедет 2"])
        try restorer(mac).restore(versionId: version.id, ofPage: source.id)
        #expect(try mac.blocks(source.id).map(\.id) == blocks.map(\.id))
        #expect(try mac.texts(target.id) == ["своё"], "Копии на другой странице не удалены")
    }

    @Test("Дубликат страницы с перенесёнными блоками: восстановление версии исходной страницы его не трогает")
    func duplicateOfMovedBlocksKept() async throws {
        let mac = try VersionsTestMac()
        let source = try mac.page("Откуда", texts: ["остаётся", "уедет"])
        let target = try mac.page("Куда", texts: ["своё"])
        let blocks = try mac.blocks(source.id)
        let version = try versionNow(mac, source.id)
        try moveBlocks([blocks[1].id], from: source.id, to: target.id, mac)
        let copy = try await mac.tree.duplicate(target.id)
        #expect(try mac.texts(copy.id) == ["своё", "уедет"])
        try restorer(mac).restore(versionId: version.id, ofPage: source.id)
        #expect(try mac.texts(target.id) == ["своё"])
        #expect(try mac.texts(copy.id) == ["своё", "уедет"], "Восстановление удалило блоки дубликата")
    }

    @Test("Унесённая ссылка на подстраницу возвращается, подстраница — снова под исходной страницей")
    func movedSubpageReturns() throws {
        let mac = try VersionsTestMac()
        let source = try mac.page("Родитель", texts: ["текст"])
        let target = try mac.page("Другая", texts: ["своё"])
        let subpage = try mac.tree.createSubpage(in: source.id, title: "Подстраница")
        let link = try #require(try mac.blocks(source.id).first { $0.linkedPageId == subpage.id })
        let version = try versionNow(mac, source.id)
        try moveBlocks([link.id], from: source.id, to: target.id, mac)
        #expect(try mac.store.pageOutline().first { $0.id == subpage.id }?.parentId == target.id)
        try restorer(mac).restore(versionId: version.id, ofPage: source.id)
        #expect(try mac.store.pageOutline().first { $0.id == subpage.id }?.parentId == source.id)
        #expect(try mac.blocks(source.id).contains { $0.id == link.id && $0.linkedPageId == subpage.id })
        #expect(try !mac.blocks(target.id).contains { $0.linkedPageId == subpage.id })
    }

    @Test("Снимок «до восстановления» и новая версия после; прошлые версии на месте")
    func snapshotsAroundRestore() throws {
        let mac = try VersionsTestMac()
        mac.recorder.start()
        let page = try mac.page("Версии", texts: ["v1"])
        let block = try #require(try mac.blocks(page.id).first)
        let first = try versionNow(mac, page.id)
        try mac.setText("v2", ofBlock: block.id)
        let second = try versionNow(mac, page.id)
        try mac.setText("v3 — не успела стать версией", ofBlock: block.id)
        try restorer(mac).restore(versionId: first.id, ofPage: page.id)
        let versions = try mac.versionList(page.id)
        #expect(versions.count == 4)
        #expect(Set(versions.map(\.id)).isSuperset(of: [first.id, second.id]))
        #expect(try mac.versions.snapshot(versions[1].id)?.blocks.first?.text.string == "v3 — не успела стать версией", "Нет снимка «до»")
        #expect(try mac.versions.snapshot(versions[0].id)?.blocks.first?.text.string == "v1", "Нет новой версии после")
        #expect(try mac.dueCount() == 0)
    }

    @Test("⌘Z восстановления — страница, перенесённые копии и подстраница как до него; ⇧⌘Z — снова как в версии")
    func undoRestore() throws {
        let mac = try VersionsTestMac()
        mac.recorder.start()
        let source = try mac.page("Источник", texts: ["а", "б", "в"])
        let target = try mac.page("Цель", texts: ["своё"])
        let subpage = try mac.tree.createSubpage(in: source.id, title: "Под")
        let version = try versionNow(mac, source.id)
        let blocks = try mac.blocks(source.id)
        let link = try #require(blocks.first { $0.linkedPageId == subpage.id })
        try moveBlocks([blocks[1].id, link.id], from: source.id, to: target.id, mac)
        try mac.setText("а — правка", ofBlock: blocks[0].id)
        try mac.updatePage(source.id) { $0.title = "Источник 2" }
        let sourceBefore = try mac.blocks(source.id)
        let targetBefore = try mac.blocks(target.id)
        let versionCount = try mac.versionList(source.id).count

        try mac.undoable { try restorer(mac).restore(versionId: version.id, ofPage: source.id) }
        #expect(try mac.texts(source.id) == ["а", "б", "в", ""])
        mac.undoManager.undo()
        #expect(try mac.blocks(source.id).map(\.id) == sourceBefore.map(\.id))
        #expect(try mac.texts(source.id) == sourceBefore.map(\.text.string))
        #expect(try mac.store.pageContent(source.id)?.page.title == "Источник 2")
        #expect(try mac.blocks(target.id).map(\.id) == targetBefore.map(\.id), "Копии на другой странице не вернулись")
        #expect(try mac.store.pageOutline().first { $0.id == subpage.id }?.parentId == target.id)
        #expect(try mac.versionList(source.id).count >= versionCount + 2, "⌘Z стёр версии")
        mac.undoManager.redo()
        #expect(try mac.blocks(source.id).map(\.id) == version.snapshotBlockIds(mac))
        #expect(try mac.store.pageOutline().first { $0.id == subpage.id }?.parentId == source.id)
        #expect(try mac.texts(target.id) == ["своё"])
    }

    @Test("Подстраница, созданная после версии, не теряется: ссылка и страница остаются")
    func newerSubpageKept() throws {
        let mac = try VersionsTestMac()
        let page = try mac.page("Родитель", texts: ["текст"])
        let version = try versionNow(mac, page.id)
        let subpage = try mac.tree.createSubpage(in: page.id, title: "Новая")
        try restorer(mac).restore(versionId: version.id, ofPage: page.id)
        #expect(try mac.store.pageOutline().first { $0.id == subpage.id }?.parentId == page.id)
        #expect(try mac.blocks(page.id).contains { $0.linkedPageId == subpage.id })
    }

    @Test("Ссылка на подстраницу, стёртую навсегда, возвращается ссылкой на удалённую страницу")
    func erasedSubpageLink() throws {
        let mac = try VersionsTestMac()
        let page = try mac.page("Родитель", texts: ["текст"])
        let subpage = try mac.tree.createSubpage(in: page.id, title: "Стёрта")
        let version = try versionNow(mac, page.id)
        try mac.tree.moveToTrash(subpage.id)
        try mac.tree.deleteForever(subpage.id)
        try restorer(mac).restore(versionId: version.id, ofPage: page.id)
        #expect(try mac.blocks(page.id).contains { $0.linkedPageId == subpage.id })
        #expect(try mac.store.pageOutline().first { $0.id == subpage.id } == nil)
    }

    @Test("Восстановление уходит на другой Mac обычными правками; там — новая версия с автором этого Mac")
    func restoreSyncs() throws {
        let here = try VersionsTestMac(name: "Mac A", syncs: true)
        let there = try VersionsTestMac(name: "Mac B", syncs: true)
        here.store.keepsDeletionMarks = true
        there.store.keepsDeletionMarks = true
        let page = try here.page("Общая", texts: ["было 1", "было 2"])
        try there.receive(here.takeOutgoing())
        let version = try versionNow(here, page.id)
        let blocks = try here.blocks(page.id)
        try here.setText("стало", ofBlock: blocks[0].id)
        try here.store.write { try $0.deleteBlock(blocks[1].id) }
        try there.receive(here.takeOutgoing())
        #expect(try there.texts(page.id) == ["стало"])
        try there.versions.clearDue(pageId: page.id, upTo: there.clock.now.addingTimeInterval(3_600))
        there.recorder.start()

        try restorer(here).restore(versionId: version.id, ofPage: page.id)
        let outgoing = try here.takeOutgoing()
        #expect(!outgoing.isEmpty, "Восстановление не попало в исходящие")
        try there.receive(outgoing)
        #expect(try there.texts(page.id) == ["было 1", "было 2"])
        #expect(try there.blocks(page.id).map(\.id) == blocks.map(\.id))
        there.clock.advance(by: 6)
        #expect(try there.versionList(page.id).first?.deviceName == "Mac A")
    }

    @Test("Версия есть, текущая страница не изменилась — восстановление ничего не ломает")
    func restoreSameState() throws {
        let mac = try VersionsTestMac()
        let page = try mac.page("Как есть", texts: ["а", "б"])
        let blocks = try mac.blocks(page.id)
        let version = try versionNow(mac, page.id)
        try restorer(mac).restore(versionId: version.id, ofPage: page.id)
        #expect(try mac.blocks(page.id) == blocks)
    }
}

extension PageVersionInfo {
    @MainActor
    func snapshotBlockIds(_ mac: VersionsTestMac) throws -> [UUID] {
        try mac.versions.snapshot(id)?.blocks.map(\.id) ?? []
    }
}
