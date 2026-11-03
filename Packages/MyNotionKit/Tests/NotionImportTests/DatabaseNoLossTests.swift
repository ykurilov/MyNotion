import Foundation
import NotesCore
import Testing
@testable import Databases
@testable import MarkdownExport
@testable import NotionImport

/// Ни одна операция 004 не теряет данных (T109, SC-310): на эталоне баз со всеми 18 типами, двусторонней связью,
/// формулами и сводками — «выгрузить → импортировать», «сменить тип → ⌘Z», «удалить свойство → вернуть», «удалить
/// базу → вернуть». После круга схема, варианты, виды, значения, связи и итоги формул и сводок — как в начале.
/// Хранилище — с подписчиками приложения и очередью пересчёта: итоги пересчитывает само приложение, а не тест.
/// Сюда, а не в `DatabasesTests`: выгрузка и импорт живут в `MarkdownExport` и `NotionImport`.
@MainActor
@Suite("Базы: без потерь (SC-310)", .serialized)
struct DatabaseNoLossTests {
    let folder: URL
    let store: NotesStore
    let undo = UndoManager()
    let operations: DatabaseOperations
    let tree: PageTreeOperations
    let queue: FormulaRecomputeQueue
    let sample: DatabaseSampleGenerator.Sample

    var databases: [UUID] { [sample.tasksId, sample.projectsId, sample.inlineTasksId] }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DatabaseNoLoss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Выгрузки"), withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")),
                           clock: HybridLogicalClock(deviceId: UUID()))
        // «Сейчас» одно на весь тест: формула «Дней до срока» не меняется между началом и концом круга.
        let moment = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        queue = FormulaRecomputeQueue(store: store, now: { moment })
        store.addWriteHook(CellIndexer())
        store.addWriteHook(ComputationHook(store: store, queue: queue, now: { moment }))
        store.addTreeAddon(DatabaseTreeAddon())
        undo.groupsByEvent = false
        operations = DatabaseOperations(store: store, undoManager: undo)
        tree = PageTreeOperations(store: store, undoManager: undo)
        sample = try DatabaseSampleGenerator(taskCount: 40, projectCount: 5).ensure(in: store)
    }

    // MARK: Круги

    @Test("Сменить тип → ⌘Z: у каждого свойства обеих баз в текст, число и множественный выбор — всё как в начале")
    func changeTypeThenUndo() async throws {
        let original = try await start()
        for databaseId in [sample.tasksId, sample.projectsId] {
            for property in try properties(databaseId) {
                for kind in [PropertyKind.text, .number, .multiSelect] where kind != property.kind {
                    try step { try operations.changeType(property.id, to: kind) }
                    try await settle()
                    #expect(try store.write { try $0.property(property.id)?.kind } == kind)
                    undo.undo()
                    try await settle()
                    expectSameDatabases(original, try fingerprint(), "«\(property.name)»: \(property.kind.rawValue) → \(kind.rawValue) → ⌘Z")
                }
            }
        }
    }

    @Test("Сменить тип в фоне (большая база) → ⌘Z: у каждого свойства в текст — всё как в начале")
    func backgroundChangeTypeThenUndo() async throws {
        let original = try await start()
        for databaseId in [sample.tasksId, sample.projectsId] {
            for property in try properties(databaseId) where property.kind != .text {
                try await operations.startChangeType(property.id, to: .text).value
                try await settle()
                #expect(try store.write { try $0.property(property.id)?.kind } == .text)
                undo.undo()
                try await operations.pendingRewrite?.value
                try await settle()
                expectSameDatabases(original, try fingerprint(), "фон: «\(property.name)»: \(property.kind.rawValue) → text → ⌘Z")
            }
        }
    }

    @Test("Удалить свойство → вернуть: из «Удалённых свойств», ⌘Z и после «Удалить навсегда» → ⌘Z — всё как в начале")
    func deletePropertyThenRestore() async throws {
        let original = try await start()
        var way = 0
        for databaseId in [sample.tasksId, sample.projectsId] {
            for property in try properties(databaseId) {
                try step { try operations.setDeleted(property.id, true) }
                try await settle()
                let circle: String
                switch way % 3 {
                case 0:
                    circle = "вернуть из «Удалённых свойств»"
                    try step { try operations.setDeleted(property.id, false) }
                case 1:
                    circle = "⌘Z"
                    undo.undo()
                default:
                    circle = "«Удалить навсегда» → ⌘Z → вернуть"
                    try step { try operations.eraseProperty(property.id) }
                    try await settle()
                    undo.undo()
                    try await settle()
                    try step { try operations.setDeleted(property.id, false) }
                }
                way += 1
                try await settle()
                expectSameDatabases(original, try fingerprint(), "«\(property.name)» (\(property.kind.rawValue)): удалить → \(circle)")
            }
        }
    }

    @Test("Удалить базу → вернуть: каждая из трёх баз в корзину, затем «Восстановить» или ⌘Z — всё как в начале, встроенная на месте")
    func trashDatabaseThenRestore() async throws {
        let original = try await start()
        let overviewBlocks = try hostBlocks()
        for (index, databaseId) in databases.enumerated() {
            try step { try tree.moveToTrash(databaseId) }
            try await settle()
            if index.isMultiple(of: 2) { try step { try tree.restore(databaseId) } } else { undo.undo() }
            try await settle()
            let title = try store.write { try $0.page(databaseId)?.title } ?? "?"
            expectSameDatabases(original, try fingerprint(), "«\(title)»: в корзину → \(index.isMultiple(of: 2) ? "восстановить" : "⌘Z")")
            #expect(try hostBlocks() == overviewBlocks, "«Обзор» со встроенной базой — как был")
        }
    }

    @Test("Выгрузить → импортировать: копия совпадает с эталоном вместе с итогами формул и сводок")
    func exportThenImport() async throws {
        _ = try await start()
        let original = try canonicalDatabases(databases, in: store, computed: true)
        let export = try MarkdownExporter(store: store).export(into: folder.appendingPathComponent("Выгрузки"))
        let prepared = try NotionExportUnpacker().prepare(export.folder)
        defer { prepared.discard() }
        let report = try NotionImporter(store: store).importExport(prepared)
        let imported = try store.pageOutline()
        let tree = PageTreeSnapshot(allPages: imported)
        let databasePages = Set(try store.write { tx throws in try tx.allDatabaseRecords() }.databases.map(\.pageId))
        let copies = try [DatabaseSampleGenerator.tasksTitle, DatabaseSampleGenerator.projectsTitle, DatabaseSampleGenerator.inlineTasksTitle]
            .map { title in
                try #require(imported.first { page in
                    page.title == title && databasePages.contains(page.id) && tree.isPage(page.id, insideBranchOf: report.rootPageId)
                }?.id)
            }
        try await settle()
        expectSameDatabases(original, try canonicalDatabases(copies, in: store, computed: true), "выгрузить → импортировать")
    }

    // MARK: Помощники

    /// Итоги формул и сводок пересчитаны с нуля; отпечаток эталона до круга.
    private func start() async throws -> [String] {
        for _ in 0..<2 {
            for databaseId in databases { queue.enqueue(databaseId) }
            try await settle()
        }
        let original = try fingerprint()
        #expect(original.contains { $0.contains("Число задач≔") } && original.contains { $0.contains("Проект (имя)≔") },
                "в отпечатке есть итоги сводок и формул")
        return original
    }

    /// Отпечаток трёх баз без дат строк: правка ячеек ставит строке новое «Изменено» — это не потеря.
    private func fingerprint() throws -> [String] {
        try canonicalDatabases(databases, in: store, editTimes: false, computed: true)
    }

    /// Пересчёты, поставленные правкой, закончились.
    private func settle() async throws {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.enqueueBarrier { done.resume() } }
    }

    private func step(_ body: () throws -> Void) rethrows {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        try body()
    }

    private func properties(_ databaseId: UUID) throws -> [DatabaseProperty] {
        try store.write { try $0.properties(ofDatabase: databaseId) }.filter { $0.kind != .title }
    }

    private func hostBlocks() throws -> [String] {
        try #require(try store.pageContent(sample.overviewId)).blocks.map { "\($0.kind.rawValue):\($0.linkedPageId?.uuidString ?? $0.text.string)" }
    }
}
