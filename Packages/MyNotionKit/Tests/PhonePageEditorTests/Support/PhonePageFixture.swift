import Foundation
import NotesCore
import Testing
@testable import PhonePageEditor

/// Страница с заданными блоками в базе во временной папке, открытая через `OpenDocuments`, и правила правки iPhone над ней.
@MainActor
final class PhonePageFixture {
    struct Spec {
        var kind: BlockKind = .paragraph
        var text: InlineText = .empty
        var indent = 0
        var checked = false
        var props: BlockProps = .empty
        var link: UUID?

        static func paragraph(_ text: String = "", indent: Int = 0, runs: [StyledRun] = []) -> Spec {
            Spec(kind: .paragraph, text: InlineText(text, runs: runs), indent: indent)
        }
        static func block(_ kind: BlockKind, _ text: String = "", indent: Int = 0, runs: [StyledRun] = [], checked: Bool = false,
                          props: BlockProps = .empty, link: UUID? = nil) -> Spec {
            Spec(kind: kind, text: InlineText(text, runs: runs), indent: indent, checked: checked, props: props, link: link)
        }
    }

    let folder: URL
    let store: NotesStore
    let openDocuments: OpenDocuments
    let pageId: UUID
    let document: PageDocument
    let session: PageEditingSession
    /// id блоков по порядку спецификаций.
    let ids: [UUID]

    init(_ specs: [Spec]) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PhonePageEditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite"))
        store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: UUID()))
        var created: [UUID] = []
        pageId = try store.write { tx in
            let page = try tx.createPage(title: "Страница")
            for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            for spec in specs {
                key = .between(key, nil)
                let block = try tx.insertBlock(Block(pageId: page.id, kind: spec.kind, text: spec.text, indent: spec.indent,
                                                     isChecked: spec.checked, linkedPageId: spec.link, sortKey: key!, props: spec.props))
                created.append(block.id)
            }
            return page.id
        }
        ids = created
        openDocuments = OpenDocuments(store: store, scheduler: IdleScheduler())
        document = try openDocuments.open(pageId)
        session = PageEditingSession(document: document, viewState: BlockViewStateStore(database: database))
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func block(_ id: UUID) throws -> Block { try #require(document.block(id)) }

    var kinds: [BlockKind] { document.blocks.map(\.kind) }
    var texts: [String] { document.blocks.map(\.text.string) }

    /// Записать открытые страницы и прочитать блоки страницы из базы.
    func savedBlocks() throws -> [Block] {
        #expect(openDocuments.saveAll())
        return try #require(try store.pageContent(pageId)).blocks
    }

    /// Правка с другого устройства: прямо в базу, затем — как после синхронизации.
    func editElsewhere(_ id: UUID, _ change: (inout Block) -> Void) throws {
        try store.write { tx in
            var block = try #require(try tx.block(id))
            change(&block)
            _ = try tx.updateBlock(block)
        }
        _ = openDocuments.applyExternalChanges(toPages: [pageId])
    }
}

/// Автосохранение, которое само не срабатывает: тест пишет через `saveAll()`.
@MainActor
final class IdleScheduler: AutosaveScheduler {
    var now: Duration { .zero }
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> any ScheduledAutosave { Never() }

    final class Never: ScheduledAutosave {
        func cancel() {}
    }
}
