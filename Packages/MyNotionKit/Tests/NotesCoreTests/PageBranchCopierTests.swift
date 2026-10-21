import Foundation
import GRDB
import Testing
@testable import NotesCore

/// Копия ветки страниц (research R7, contracts/page-operations.md, «Дублирование»). Название «(1)», место под
/// оригиналом и отмену проверяет операция дублирования (US4); здесь — что копируется и как.
@Suite("Копия ветки страниц")
struct PageBranchCopierTests {
    let folder: TemporaryFolder
    let store: NotesStore
    let ref = AttachmentRef(name: "Фото.png", byteCount: 2_048, contentType: "public.png", sha256: String(repeating: "b", count: 64))

    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
    }

    struct Branch {
        var root: Page, child: Page, grandchild: Page, trashedChild: Page, outside: Page
    }

    /// Корень (иконка, обложка, вид) → ребёнок → внук; ребёнок в корзине; страница вне ветки.
    /// В корне: ссылки на детей, ссылка на страницу вне ветки, упоминания, дата с напоминанием, картинка, колонки.
    func makeBranch(dateStyle: DateMention.TemplateRelative? = nil) throws -> Branch {
        try store.write { tx in
            let outside = try tx.createPage(title: "Вне ветки")
            var root = try tx.createPage(title: "Проект", icon: "🚀")
            root.cover = PageCover(source: .file(ref), offset: 0.3)
            root.isFullWidth = true
            root.isSmallText = true
            root.favorite = FractionalSortKey(rawValue: "f")
            root.visitedAt = Date()
            root = try tx.updatePage(root)
            let child = try tx.createPage(title: "Ребёнок", parentId: root.id)
            let grandchild = try tx.createPage(title: "Внук", parentId: child.id)
            let trashedChild = try tx.createPage(title: "В корзине", parentId: root.id)
            var trashed = trashedChild
            trashed.trashedAt = Date()
            try tx.updatePage(trashed)

            for block in try tx.blocks(ofPage: root.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            func add(_ block: (FractionalSortKey) -> Block) throws -> Block {
                key = .between(key, nil)
                return try tx.insertBlock(block(key!))
            }
            _ = try add { Block(pageId: root.id, kind: .pageLink, linkedPageId: child.id, sortKey: $0) }
            _ = try add { Block(pageId: root.id, kind: .pageLink, linkedPageId: trashedChild.id, sortKey: $0) }
            _ = try add { Block(pageId: root.id, kind: .pageLink, linkedPageId: outside.id, sortKey: $0) }
            let date = DateMention(start: "2026-01-05", includesTime: false, timeZone: "Europe/Moscow",
                                   reminder: DateMention.Reminder(fireAt: Date(timeIntervalSince1970: 1_800_000_000)), templateRelative: dateStyle)
            let atoms = "Упоминания: \u{FFFC} и \u{FFFC}, дата \u{FFFC}"
            let positions = atoms.utf16.enumerated().filter { $0.element == InlineText.objectReplacementCharacter }.map(\.offset)
            _ = try add { Block(pageId: root.id, text: InlineText(atoms, runs: [
                StyledRun(start: positions[0], length: 1, style: .mention(child.id)),
                StyledRun(start: positions[1], length: 1, style: .mention(outside.id)),
                StyledRun(start: positions[2], length: 1, style: .date(date)),
            ]), sortKey: $0) }
            var imageProps = BlockProps()
            imageProps.attachment = ref
            _ = try add { Block(pageId: root.id, kind: .image, sortKey: $0, props: imageProps) }
            let columns = try add { Block(pageId: root.id, kind: .columnList, sortKey: $0) }
            let column = try tx.insertBlock(Block(pageId: root.id, kind: .column, sortKey: .between(nil, nil), containerId: columns.id))
            try tx.insertBlock(Block(pageId: root.id, text: InlineText("В колонке"), sortKey: .between(nil, nil), containerId: column.id))
            try tx.insertBlock(Block(pageId: child.id, kind: .pageLink, linkedPageId: grandchild.id,
                                     sortKey: .between(try tx.blocks(ofPage: child.id).last?.sortKey, nil)))
            return Branch(root: root, child: child, grandchild: grandchild, trashedChild: trashedChild, outside: outside)
        }
    }

    @Test("Копируются страницы ветки вне корзины, все потоки, иконка, обложка, вид; id новые")
    func copiesBranchPagesAndFields() throws {
        let branch = try makeBranch()
        let result = try store.write { try PageBranchCopier.copy(branch.root.id, in: $0, title: "Проект (1)", parentId: nil, sortKey: .between(branch.root.sortKey, nil)) }
        let pages = try store.pageOutline()
        let copy = try #require(pages.first { $0.id == result.rootId })
        #expect(copy.title == "Проект (1)")
        #expect(copy.icon == "🚀")
        #expect(copy.cover == PageCover(source: .file(ref), offset: 0.3))
        #expect(copy.isFullWidth && copy.isSmallText)
        #expect(copy.favorite == nil && copy.visitedAt == nil, "избранное и недавние — не содержимое: копия их не получает")
        #expect(Set(result.pageIds.keys) == [branch.root.id, branch.child.id, branch.grandchild.id], "страница в корзине не копируется")
        #expect(!result.pageIds.values.contains { [branch.root.id, branch.child.id, branch.grandchild.id].contains($0) })
        let childCopy = try #require(pages.first { $0.id == result.pageIds[branch.child.id] })
        let grandchildCopy = try #require(pages.first { $0.id == result.pageIds[branch.grandchild.id] })
        #expect(childCopy.parentId == copy.id && childCopy.title == "Ребёнок")
        #expect(grandchildCopy.parentId == childCopy.id && grandchildCopy.title == "Внук")

        let original = try #require(try store.pageContent(branch.root.id)).blocks
        let copied = try #require(try store.pageContent(copy.id)).blocks
        #expect(copied.count == original.count - 1, "ссылка на страницу в корзине не копируется")
        #expect(Set(copied.map(\.id)).isDisjoint(with: original.map(\.id)))
        #expect(copied.contains { $0.text.string == "В колонке" && $0.containerId != nil }, "потоки колонок скопированы")
    }

    @Test("pageLink внутри ветки ведёт на копию, вне ветки — как было; упоминания — как были")
    func linksAndMentions() throws {
        let branch = try makeBranch()
        let result = try store.write { try PageBranchCopier.copy(branch.root.id, in: $0, title: "Копия", parentId: nil, sortKey: .between(branch.root.sortKey, nil)) }
        let copied = try #require(try store.pageContent(result.rootId)).blocks
        let links = copied.filter { $0.kind == .pageLink }.compactMap(\.linkedPageId)
        #expect(links == [result.pageIds[branch.child.id]!, branch.outside.id])
        let childLinks = try #require(try store.pageContent(result.pageIds[branch.child.id]!)).blocks.compactMap(\.linkedPageId)
        #expect(childLinks == [result.pageIds[branch.grandchild.id]!])
        let mentions = copied.flatMap(\.text.runs).compactMap { run -> UUID? in if case .mention(let id) = run.style { id } else { nil } }
        #expect(mentions == [branch.child.id, branch.outside.id], "упоминания ведут на прежние страницы, как у Notion")
    }

    @Test("Даты те же, но у копии напоминания выключены; файлы — та же AttachmentRef и считаются ссылкой")
    func datesRemindersAndFiles() throws {
        let branch = try makeBranch()
        let result = try store.write { try PageBranchCopier.copy(branch.root.id, in: $0, title: "Копия", parentId: nil, sortKey: .between(branch.root.sortKey, nil)) }
        let copied = try #require(try store.pageContent(result.rootId)).blocks
        let originalDate = try #require(try store.pageContent(branch.root.id)?.blocks.flatMap(\.text.runs).compactMap { run -> DateMention? in
            if case .date(let date) = run.style { date } else { nil } }.first)
        let date = try #require(copied.flatMap(\.text.runs).compactMap { run -> DateMention? in if case .date(let date) = run.style { date } else { nil } }.first)
        #expect(date.start == originalDate.start && date.includesTime == originalDate.includesTime && date.timeZone == originalDate.timeZone)
        #expect(date.reminder == nil)
        #expect(date.id != originalDate.id, "у даты копии свой id — id напоминания и уведомления")
        #expect(copied.first { $0.kind == .image }?.props.attachment == ref)

        // Удаление оригинала навсегда: файл всё ещё упомянут блоком копии (по нему считает ссылки 002).
        try store.write { tx in
            for id in [branch.grandchild.id, branch.child.id, branch.root.id] { try tx.erasePage(id) }
        }
        let references = try store.database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM block WHERE instr(upper(props), upper(?)) > 0", arguments: [ref.id.uuidString]) ?? 0
        }
        #expect(references == 1)
    }

    @Test("Даты шаблона «@сегодня» и «@сейчас» становятся моментом создания копии; поле очищается")
    func templateRelativeDatesResolve() throws {
        let branch = try makeBranch(dateStyle: .today)
        // 20.10.2026 21:30 по Москве = 18:30 UTC.
        let now = Date(timeIntervalSince1970: 1_792_521_000)
        let today = try store.write { try PageBranchCopier.copy(branch.root.id, in: $0, title: "К", parentId: nil, sortKey: .between(nil, nil), now: now) }
        let date = try #require(try store.pageContent(today.rootId)?.blocks.flatMap(\.text.runs).compactMap { run -> DateMention? in
            if case .date(let date) = run.style { date } else { nil } }.first)
        #expect(date.start == "2026-10-20" && !date.includesTime && date.templateRelative == nil)

        try store.write { tx in
            for block in try tx.blocks(ofPage: branch.root.id) {
                var changed = block
                changed.text = InlineText(block.text.string, runs: block.text.runs.map { run in
                    guard case .date(var date) = run.style else { return run }
                    date.templateRelative = .now
                    return StyledRun(start: run.start, length: run.length, style: .date(date))
                })
                if changed != block { try tx.updateBlock(changed) }
            }
        }
        let current = try store.write { try PageBranchCopier.copy(branch.root.id, in: $0, title: "К2", parentId: nil, sortKey: .between(nil, nil), now: now) }
        let moment = try #require(try store.pageContent(current.rootId)?.blocks.flatMap(\.text.runs).compactMap { run -> DateMention? in
            if case .date(let date) = run.style { date } else { nil } }.first)
        #expect(moment.start == "2026-10-20T21:30" && moment.includesTime && moment.templateRelative == nil, "\(moment)")

        let kept = try store.write { try PageBranchCopier.copy(branch.root.id, in: $0, title: "К3", parentId: nil, sortKey: .between(nil, nil), now: now,
                                                                 resolvesTemplateDates: false) }
        let relative = try #require(try store.pageContent(kept.rootId)?.blocks.flatMap(\.text.runs).compactMap { run -> DateMention? in
            if case .date(let date) = run.style { date } else { nil } }.first)
        #expect(relative.templateRelative == .now, "копия шаблона-шаблоном хранит даты относительными")
    }

    @Test("Одна транзакция: подписчик видит все страницы и блоки копии разом")
    func singleTransaction() throws {
        let branch = try makeBranch()
        let recorder = ChangeRecorder()
        store.addWriteHook(recorder)
        _ = try store.write { try PageBranchCopier.copy(branch.root.id, in: $0, title: "К", parentId: nil, sortKey: .between(nil, nil)) }
        #expect(recorder.commits.count == 1)
        #expect(recorder.commits.first?.pages.filter(\.isNew).count == 3)
    }
}

/// Подписчик записи: какие транзакции прошли.
final class ChangeRecorder: NotesWriteHook, @unchecked Sendable {
    private(set) var commits: [NotesChanges] = []
    func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws { commits.append(changes) }
}
