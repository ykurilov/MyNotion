import Foundation
import Testing
@testable import NotesCore
@testable import Sync

/// Слияние правок двух Mac (research R8): поля — поздняя метка побеждает, текст одного блока с двух сторон —
/// конфликт с обеими версиями, петли в дереве отклоняются, стёртое и убранное в корзину не съедает правки.
@MainActor
@Suite("Слияние правок")
struct ChangeMergerTests {
    let numbering = TestJournalNumbering()
    let a: SyncTestMac
    let b: SyncTestMac

    init() throws {
        a = try SyncTestMac(name: "Mac A", wallMillis: 10_000)
        b = try SyncTestMac(name: "Mac B", wallMillis: 10_000)
    }

    // MARK: Поля

    @Test("Поля страницы и блока: побеждает правка с более поздней меткой, у каждого поля своя")
    func laterFieldWins() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering, title: "Старое")

        a.wall.set(30_000)
        try a.rename(shared.page, "С Mac A")
        try a.tree.setIcon(shared.page, to: "🍎")
        try a.store.write { tx in
            var block = try #require(try tx.block(shared.block))
            block.kind = .heading1
            try tx.updateBlock(block)
        }
        b.wall.set(40_000)
        try b.rename(shared.page, "С Mac B")
        try b.store.write { tx in
            var block = try #require(try tx.block(shared.block))
            block.kind = .checkbox
            block.isChecked = true
            try tx.updateBlock(block)
        }

        try exchange([a, b], numbering: numbering)

        for mac in [a, b] {
            let page = try #require(try mac.page(shared.page))
            #expect(page.title == "С Mac B", "\(mac.name): позднее название")
            #expect(page.icon == "🍎", "\(mac.name): иконку меняли только на A")
            let block = try #require(try mac.block(shared.block, in: shared.page))
            #expect(block.kind == .checkbox && block.isChecked, "\(mac.name): поздний тип блока")
            #expect(block.text.string == "текст")
            #expect(try mac.conflicts().isEmpty)
        }
    }

    @Test("Правки разных блоков сливаются молча; перенос строки, подчёркнутый и иконка — обычные поля")
    func differentBlocksMergeSilently() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)
        let second = try a.store.write { tx in
            try tx.insertBlock(Block(pageId: shared.page, text: InlineText("второй"),
                                     sortKey: .between(try #require(try tx.block(shared.block)).sortKey, nil))).id
        }
        try exchange([a, b], numbering: numbering)

        a.wall.set(30_000)
        let styled = InlineText("первая строка\nвторая строка", runs: [StyledRun(start: 0, length: 6, style: .underline)])
        try a.store.write { tx in
            var block = try #require(try tx.block(shared.block))
            block.text = styled
            try tx.updateBlock(block)
        }
        b.wall.set(31_000)
        try b.setText("второй, поправленный на B", ofBlock: second)
        try b.tree.setIcon(shared.page, to: "📘")

        try exchange([a, b], numbering: numbering)

        for mac in [a, b] {
            let blocks = try mac.blocks(shared.page)
            #expect(blocks.map(\.text) == [styled, InlineText("второй, поправленный на B")], "\(mac.name)")
            #expect(try mac.page(shared.page)?.icon == "📘")
            #expect(try mac.conflicts().isEmpty, "\(mac.name): разные блоки — без конфликта")
        }
    }

    // MARK: Текст одного блока

    @Test("Одновременная правка текста одного блока — конфликт «Две версии», ни одна версия не потеряна")
    func concurrentTextEditBecomesConflict() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)

        a.wall.set(30_000)
        try a.setText("версия с Mac A", ofBlock: shared.block)
        b.wall.set(40_000)
        try b.setText("версия с Mac B", ofBlock: shared.block)

        try exchange([a, b], numbering: numbering)

        let shownOnA = try #require(try a.block(shared.block, in: shared.page)).text
        let shownOnB = try #require(try b.block(shared.block, in: shared.page)).text
        #expect(shownOnA == shownOnB, "В блоке на обоих Mac одна и та же версия")
        for mac in [a, b] {
            let conflicts = try mac.conflicts()
            #expect(conflicts.count == 1, "\(mac.name): одна метка «Две версии»")
            let conflict = try #require(conflicts.first)
            #expect(conflict.blockId == shared.block)
            #expect(Set([conflict.localVersion.string, conflict.remoteVersion.string]) == ["версия с Mac A", "версия с Mac B"],
                    "\(mac.name): обе версии целы")
        }
        #expect(a.notices.contains(.textConflict(pageId: shared.page, blockId: shared.block)))
    }

    @Test("Правка поверх уже полученной версии — не конфликт: текст просто обновляется")
    func sequentialTextEditsFastForward() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)
        a.wall.set(30_000)
        try a.setText("сначала A", ofBlock: shared.block)
        try exchange([a, b], numbering: numbering)
        b.wall.set(20_000)  // часы B отстают — правка всё равно позже полученной
        try b.setText("потом B", ofBlock: shared.block)
        try exchange([a, b], numbering: numbering)

        for mac in [a, b] {
            #expect(try mac.block(shared.block, in: shared.page)?.text.string == "потом B", "\(mac.name)")
            #expect(try mac.conflicts().isEmpty)
        }
    }

    @Test("Выбор версии на одном Mac снимает «Две версии» и на другом")
    func resolutionSpreadsToOtherMac() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)
        a.wall.set(30_000)
        try a.setText("версия A", ofBlock: shared.block)
        b.wall.set(40_000)
        try b.setText("версия B", ofBlock: shared.block)
        try exchange([a, b], numbering: numbering)

        let conflict = try #require(try a.conflicts().first)
        a.wall.set(50_000)
        try a.store.write { tx in
            try tx.resolveConflict(conflict.id)
            var block = try #require(try tx.block(shared.block))
            block.text = InlineText("версия A")
            try tx.updateBlock(block)
        }
        try exchange([a, b], numbering: numbering)

        for mac in [a, b] {
            #expect(try mac.conflicts().isEmpty, "\(mac.name): выбор дошёл")
            #expect(try mac.block(shared.block, in: shared.page)?.text.string == "версия A")
        }
    }

    @Test("Удаление блока на одном Mac и правка его текста на другом — блок остаётся с правкой")
    func editBeatsUnawareBlockDeletion() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)
        let second = try a.store.write { tx in
            try tx.insertBlock(Block(pageId: shared.page, text: InlineText("удалят"),
                                     sortKey: .between(try #require(try tx.block(shared.block)).sortKey, nil))).id
        }
        try exchange([a, b], numbering: numbering)

        a.wall.set(30_000)
        try a.store.write { try $0.deleteBlock(second) }
        b.wall.set(25_000)
        try b.setText("а я его правил", ofBlock: second)
        try exchange([a, b], numbering: numbering)

        for mac in [a, b] {
            #expect(try mac.block(second, in: shared.page)?.text.string == "а я его правил", "\(mac.name)")
        }
    }

    // MARK: Дерево

    @Test("Перенос, который дал бы петлю, отклоняется: дерево на обоих Mac одно, без петли и без потерь")
    func loopingMoveIsRejected() throws {
        let p = try sharedPage(on: a, others: [b], numbering: numbering, title: "P").page
        let q = try sharedPage(on: a, others: [b], numbering: numbering, title: "Q").page

        a.wall.set(30_000)
        try a.tree.move(p, toParent: q, at: 0)
        b.wall.set(40_000)
        try b.tree.move(q, toParent: p, at: 0)

        try exchange([a, b], numbering: numbering)

        #expect(try a.parents() == b.parents(), "Деревья сошлись")
        for mac in [a, b] {
            let tree = try mac.store.pageTree()
            #expect(tree.page(p) != nil && tree.page(q) != nil, "\(mac.name): обе страницы видны в дереве")
            #expect(tree.parentId(of: p) == q, "\(mac.name): ранний перенос остался")
            #expect(tree.parentId(of: q) != p, "\(mac.name): поздний перенос с петлёй отклонён")
            let linksToQInP = try mac.blocks(p).filter { $0.linkedPageId == q }
            #expect(linksToQInP.isEmpty, "\(mac.name): в P нет ссылки на Q, раз Q не внутри P")
        }
    }

    @Test("Одну ветку перенесли в разные места на двух Mac — дерево сходится к одному виду, страницы целы")
    func branchMovedDifferentlyConverges() throws {
        let left = try sharedPage(on: a, others: [b], numbering: numbering, title: "Слева").page
        let right = try sharedPage(on: a, others: [b], numbering: numbering, title: "Справа").page
        let branch = try sharedPage(on: a, others: [b], numbering: numbering, title: "Ветка").page
        let child = try a.tree.createSubpage(in: branch, title: "Лист").id
        try exchange([a, b], numbering: numbering)

        a.wall.set(30_000)
        try a.tree.move(branch, toParent: left, at: 0)
        b.wall.set(40_000)
        try b.tree.move(branch, toParent: right, at: 0)
        try exchange([a, b], numbering: numbering)

        #expect(try a.parents() == b.parents())
        for mac in [a, b] {
            let tree = try mac.store.pageTree()
            #expect(tree.parentId(of: branch) == right, "\(mac.name): поздний перенос")
            #expect(tree.parentId(of: child) == branch, "\(mac.name): ветка переехала целиком")
            #expect(try mac.blocks(right).contains { $0.linkedPageId == branch })
            #expect(try !mac.blocks(left).contains { $0.linkedPageId == branch })
        }
    }

    @Test("Подстраница из «/» доходит до другого Mac: ссылка на своём месте, страница под родителем; ⌘Z доходит тоже")
    func inlineSubpageSyncs() throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        a.tree.undoManager = undoManager
        let shared = try sharedPage(on: a, others: [b], numbering: numbering, text: "до")
        let tail = try a.store.write { tx in
            try tx.insertBlock(Block(pageId: shared.page, text: InlineText("после"), sortKey: .between(.between(nil, nil), nil)))
        }
        try exchange([a, b], numbering: numbering)

        a.wall.set(30_000)
        undoManager.beginUndoGrouping()
        let subpage = try a.tree.createSubpage(in: shared.page, title: "План", linkAt: .after(blockId: shared.block))
        undoManager.endUndoGrouping()
        try exchange([a, b], numbering: numbering)

        #expect(try b.store.pageTree().parentId(of: subpage.id) == shared.page)
        #expect(try b.blocks(shared.page).map { $0.linkedPageId ?? $0.id } == [shared.block, subpage.id, tail.id])

        a.wall.set(40_000)
        undoManager.undo()
        try exchange([a, b], numbering: numbering)
        #expect(try b.blocks(shared.page).map(\.id) == [shared.block, tail.id])
        #expect(try b.store.trashEntries().map(\.id) == [subpage.id])
    }

    @Test("«Преобразовать в страницу» с детьми доходит до другого Mac: дети и подстраница внутри новой; ⌘Z доходит тоже")
    func turnIntoSubpageWithChildrenSyncs() throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let shared = try sharedPage(on: a, others: [b], numbering: numbering, text: "Раздел")
        let child = try a.store.write { tx in
            var toggle = try #require(try tx.block(shared.block))
            toggle.kind = .toggle
            try tx.updateBlock(toggle)
            return try tx.insertBlock(Block(pageId: shared.page, kind: .bulletItem, text: InlineText("пункт"), indent: 1,
                                            sortKey: .between(toggle.sortKey, nil)))
        }
        let inner = try a.tree.createSubpage(in: shared.page, title: "Внутри", linkAt: .after(blockId: child.id))
        try a.store.write { tx in
            var link = try #require(try tx.blocks(ofPage: shared.page).first { $0.linkedPageId == inner.id })
            link.indent = 1
            try tx.updateBlock(link)
        }
        try exchange([a, b], numbering: numbering)

        a.wall.set(30_000)
        a.tree.undoManager = undoManager
        undoManager.beginUndoGrouping()
        let subpage = try a.tree.turnIntoSubpage(shared.block, in: shared.page)
        undoManager.endUndoGrouping()
        try exchange([a, b], numbering: numbering)

        for mac in [a, b] {
            #expect(try mac.blocks(shared.page).map(\.linkedPageId) == [subpage.id], "\(mac.name)")
            #expect(try mac.blocks(subpage.id).map { $0.linkedPageId == nil ? $0.text.string : "→" } == ["пункт", "→"], "\(mac.name)")
            #expect(try mac.store.pageTree().parentId(of: inner.id) == subpage.id, "\(mac.name)")
        }
        #expect(try a.parents() == b.parents())

        a.wall.set(40_000)
        undoManager.undo()
        try exchange([a, b], numbering: numbering)
        for mac in [a, b] {
            #expect(try mac.blocks(shared.page).map { $0.linkedPageId == nil ? $0.text.string : "→" } == ["Раздел", "пункт", "→"],
                    "\(mac.name)")
            #expect(try mac.store.pageTree().parentId(of: inner.id) == shared.page, "\(mac.name)")
            #expect(try mac.store.trashEntries().map(\.id) == [subpage.id], "\(mac.name)")
        }
    }

    // MARK: Корзина и стирание

    @Test("Правка страницы, которую на другом Mac убрали в корзину, возвращает её; Юрий видит уведомление")
    func editReturnsPageFromTrash() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)

        a.wall.set(30_000)
        try a.tree.moveToTrash(shared.page)
        b.wall.set(25_000)  // правка не позже по часам, но B о корзине не знал
        try b.setText("правка без связи", ofBlock: shared.block)

        try exchange([a, b], numbering: numbering)

        for mac in [a, b] {
            let page = try #require(try mac.page(shared.page))
            #expect(page.trashedAt == nil, "\(mac.name): страница вернулась из корзины")
            #expect(try mac.block(shared.block, in: shared.page)?.text.string == "правка без связи")
        }
        #expect(a.notices.contains { if case .pageReturnedFromTrash(shared.page, _) = $0 { true } else { false } },
                "На Mac, где удаляли, — уведомление")
    }

    @Test("Убрали в корзину, зная все правки — страница остаётся в корзине")
    func informedTrashStays() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)
        b.wall.set(25_000)
        try b.setText("правка до корзины", ofBlock: shared.block)
        try exchange([a, b], numbering: numbering)
        a.wall.set(30_000)
        try a.tree.moveToTrash(shared.page)
        try exchange([a, b], numbering: numbering)

        for mac in [a, b] {
            #expect(try mac.page(shared.page)?.trashedAt != nil, "\(mac.name)")
        }
    }

    @Test("Правка страницы, стёртой навсегда на другом Mac без знания о правке, возвращает её в корзину на всех Mac")
    func editRevivesUnawarelyErasedPage() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)

        a.wall.set(30_000)
        try a.tree.moveToTrash(shared.page)
        try a.tree.deleteForever(shared.page)
        b.wall.set(25_000)
        try b.setText("правка без связи", ofBlock: shared.block)

        try exchange([a, b], numbering: numbering)

        for mac in [a, b] {
            let page = try #require(try mac.page(shared.page), "\(mac.name): страница не пропала")
            #expect(page.trashedAt != nil, "\(mac.name): страница в корзине")
            #expect(try mac.block(shared.block, in: shared.page)?.text.string == "правка без связи", "\(mac.name): правка цела")
            #expect(try !mac.store.pageTombstones().contains { $0.pageId == shared.page })
        }
        #expect(a.notices.contains { if case .pageRevivedInTrash(shared.page, _) = $0 { true } else { false } })
        #expect(b.notices.contains { if case .pageRevivedInTrash(shared.page, _) = $0 { true } else { false } })
    }

    @Test("Стирание навсегда побеждает правки, сделанные до него")
    func eraseBeatsEarlierEdits() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)
        b.wall.set(25_000)
        try b.setText("правка до стирания", ofBlock: shared.block)
        try exchange([a, b], numbering: numbering)

        a.wall.set(30_000)
        try a.tree.moveToTrash(shared.page)
        try a.tree.deleteForever(shared.page)
        try exchange([a, b], numbering: numbering)

        for mac in [a, b] {
            #expect(try mac.page(shared.page) == nil, "\(mac.name): страница стёрта")
            #expect(try mac.store.pageTombstones().contains { $0.pageId == shared.page }, "\(mac.name): надгробие есть")
        }
        #expect(!b.notices.contains { if case .pageRevivedInTrash = $0 { true } else { false } })
    }

    // MARK: Надгробия

    @Test("Надгробия и помеченные блоки стираются только после подтверждения всеми устройствами")
    func marksAreErasedOnlyAfterEveryDeviceConfirmed() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)
        let doomed = try sharedPage(on: a, others: [b], numbering: numbering, title: "Сотрут").page
        let second = try a.store.write { tx in
            try tx.insertBlock(Block(pageId: shared.page, text: InlineText("удалят"),
                                     sortKey: .between(try #require(try tx.block(shared.block)).sortKey, nil))).id
        }
        try exchange([a, b], numbering: numbering)

        a.wall.set(30_000)
        try a.store.write { try $0.deleteBlock(second) }
        try a.tree.moveToTrash(doomed)
        try a.tree.deleteForever(doomed)
        _ = try a.takeOutgoing()
        let account = SyncAccountStore(store: a.store)
        try account.recordSent(seq: numbering.next())
        let lastSeq = numbering.lastSeq
        #expect(try deletionMarkCount(a.store) == 1, "Пока Sync включён, удалённый блок остаётся пометкой")
        #expect(try a.store.pageTombstones().contains { $0.pageId == doomed })

        let collector = TombstoneCollector(store: a.store)
        try collector.collect(deviceAcks: [lastSeq, lastSeq - 1])
        #expect(try deletionMarkCount(a.store) == 1, "Одно устройство ещё не подтвердило")
        #expect(try a.store.pageTombstones().contains { $0.pageId == doomed })

        try collector.collect(deviceAcks: [lastSeq, lastSeq])
        #expect(try deletionMarkCount(a.store) == 0)
        #expect(try a.store.pageTombstones().isEmpty)
        #expect(try a.blocks(shared.page).map(\.text.string) == ["текст"], "Живые блоки не тронуты")
    }

    // MARK: Повтор пачки

    @Test("Применение одной пачки дважды ничего не меняет")
    func applyingBatchTwiceIsHarmless() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)
        a.wall.set(30_000)
        try a.setText("правка", ofBlock: shared.block)
        try a.rename(shared.page, "Новое название")
        try a.tree.createSubpage(in: shared.page, title: "Подстраница")
        let batches = try a.takeOutgoing()

        try b.receive(batches, numbering: numbering)
        _ = try b.takeOutgoing()
        let once = try contentDump(b.store)

        try b.receive(batches, numbering: numbering)
        #expect(try contentDump(b.store) == once)
        #expect(try b.takeOutgoing().isEmpty, "Повтор не рождает новых изменений")
    }
}
