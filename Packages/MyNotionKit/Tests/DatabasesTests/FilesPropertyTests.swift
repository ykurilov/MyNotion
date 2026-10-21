import Foundation
import GRDB
import Testing
@testable import Attachments
@testable import Databases
@testable import NotesCore

/// «Файлы и медиа» (T067, spec US2, сценарий 5; FR-314): несколько файлов и ссылок в ячейке, лимит 100 МБ, счётчик
/// ссылок 002 — файл не стирается, пока он в ячейке или в хранимой версии страницы.
@MainActor
@Suite("Свойство «Файлы и медиа» (US2)")
struct FilesPropertyTests {
    let folder: URL
    let store: NotesStore
    let attachments: AttachmentStore
    let undo = UndoManager()
    let operations: DatabaseOperations
    let quiet: DatabaseOperations
    let base: CreatedDatabase
    let row: UUID
    let files: DatabaseProperty
    /// Часы сборщика сирот.
    let start = Date(timeIntervalSince1970: 1_900_000_000)

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("dbfiles-us2-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        let start = start
        attachments = AttachmentStore(store: store, folder: folder.appendingPathComponent("Attachments", isDirectory: true), now: { start })
        store.addWriteHook(CellIndexer())
        store.addWriteHook(AttachmentReferenceCounter(now: { start }))
        undo.groupsByEvent = false
        operations = DatabaseOperations(store: store, undoManager: undo)
        quiet = DatabaseOperations(store: store)
        base = try quiet.createDatabase(in: nil, isInline: false, title: "Задачи")
        row = try quiet.addRow(to: base.databaseId, in: base.viewId, at: .bottom, title: "Отчёт")
        files = try quiet.addProperty(to: base.databaseId, name: "Файлы", kind: .files)
    }

    func step(_ body: () throws -> Void) rethrows {
        undo.beginUndoGrouping()
        try body()
        undo.endUndoGrouping()
    }

    func source(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent("Оригиналы", isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func cellItems() throws -> [FilesValue.Item] {
        FilesValue.items(try store.write { tx throws in try tx.cell(rowId: row, propertyId: files.id)?.value })
    }

    func orphanedAt(_ id: UUID) throws -> Date? { try attachments.record(id)?.orphanedAt }

    @Test("Несколько файлов и ссылок: добавляются в конец одним шагом, показ — имена через запятую; убрать один — ⌘Z")
    func severalItems() throws {
        let pdf = try attachments.importFile(at: try source("Счёт.pdf", "pdf"))
        let png = try attachments.importFile(at: try source("Схема.png", "png"))
        let link = try #require(FilesValue.link("example.com/docs/plan.pdf"))
        #expect(link == .link(url: "https://example.com/docs/plan.pdf", name: "plan.pdf"))
        try step { try operations.addFiles([.file(pdf), .file(png)], rowId: row, propertyId: files.id) }
        try step { try operations.addFiles([link], rowId: row, propertyId: files.id) }
        #expect(try cellItems() == [.file(pdf), .file(png), link])
        let catalog = try DatabaseCatalog.read(base.databaseId, in: store)
        let shown = PropertyTypes.type(for: .files).displayText(try store.write { tx throws in try tx.cell(rowId: row, propertyId: files.id)?.value },
                                                                 in: catalog.context(for: files))
        #expect(shown == "Счёт.pdf, Схема.png, plan.pdf")
        try step { try operations.removeFile(at: 1, rowId: row, propertyId: files.id) }
        #expect(try cellItems() == [.file(pdf), link])
        undo.undo()
        #expect(try cellItems() == [.file(pdf), .file(png), link])
        undo.undo()
        undo.undo()
        #expect(try cellItems().isEmpty)
        #expect(try store.write { tx throws in try tx.cell(rowId: row, propertyId: files.id)?.value } == nil, "пустой список — пустое значение")
    }

    @Test("Ссылка: схема дописывается, имя — последняя часть пути или адрес; не ссылка — не принимается")
    func links() {
        #expect(FilesValue.link("https://notion.so") == .link(url: "https://notion.so", name: "notion.so"))
        #expect(FilesValue.link("  http://site.ru/a/  ") == .link(url: "http://site.ru/a/", name: "a"))
        #expect(FilesValue.link("просто текст") == nil)
        #expect(FilesValue.link("") == nil)
    }

    @Test("Картинка — уменьшенной копией, остальное — плашкой с именем")
    func images() throws {
        let png = try attachments.importFile(at: try source("Схема.png", "png"))
        let pdf = try attachments.importFile(at: try source("Счёт.pdf", "pdf"))
        #expect(FilesValue.isImage(.file(png)))
        #expect(!FilesValue.isImage(.file(pdf)))
        #expect(!FilesValue.isImage(.link(url: "https://a.ru/x.png", name: "x.png")))
    }

    @Test("Файл больше 100 МБ не берётся — сообщение как в 002, записи нет")
    func sizeLimit() throws {
        let url = folder.appendingPathComponent("большой.mov")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(AttachmentRef.maximumByteCount + 1))
        try handle.close()
        #expect(throws: AttachmentError.tooLarge(name: "большой.mov")) { try attachments.importFile(at: url) }
        #expect(AttachmentError.tooLarge(name: "большой.mov").localizedDescription == "Файл больше 100 МБ — MyNotion такие не хранит")
        #expect(try attachments.allRecords().isEmpty)
    }

    @Test("Счётчик ссылок: файл в ячейке — не сирота; убрали — сирота; ⌘Z — снова живой; в версии — сборщик не стирает")
    func referenceCounting() async throws {
        let pdf = try attachments.importFile(at: try source("Счёт.pdf", "pdf"))
        #expect(try orphanedAt(pdf.id) != nil, "до вставки копия — сирота")
        try step { try operations.addFiles([.file(pdf)], rowId: row, propertyId: files.id) }
        #expect(try orphanedAt(pdf.id) == nil)
        try step { try operations.removeFile(at: 0, rowId: row, propertyId: files.id) }
        #expect(try orphanedAt(pdf.id) == start)
        undo.undo()
        #expect(try orphanedAt(pdf.id) == nil)

        // Пока файл в ячейке, сборщик его не трогает даже через 31 день.
        let later = start.addingTimeInterval(31 * 86_400)
        let firstPass = try await AttachmentCollector(attachments: attachments, now: { later }).collect(transport: nil)
        #expect(firstPass.isEmpty)

        // Ячейку очистили, но файл есть в хранимой версии строки — тоже не стирается.
        try quiet.setCell(rowId: row, propertyId: files.id, value: nil)
        try await store.database.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO page_version_file (versionId, fileId) VALUES (?, ?)", arguments: ["v1", pdf.id.uuidString.lowercased()])
        }
        let secondPass = try await AttachmentCollector(attachments: attachments, now: { later }).collect(transport: nil)
        #expect(secondPass.isEmpty)
        try await store.database.dbWriter.write { db in try db.execute(sql: "DELETE FROM page_version_file") }
        let lastPass = try await AttachmentCollector(attachments: attachments, now: { later }).collect(transport: nil)
        #expect(lastPass == [pdf.id])
    }
}
