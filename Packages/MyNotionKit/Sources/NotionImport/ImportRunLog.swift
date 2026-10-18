import Foundation
import GRDB
import NotesCore

/// Журнал импортов — таблица `import_run` (data-model.md, «ImportRun»). Запись идёт внутри транзакции ядра,
/// чтобы ветка и её строка журнала появлялись и пропадали вместе.
struct ImportRunLog {
    let store: NotesStore

    func insertRunning(id: UUID, fingerprint: String, startedAt: Date, rootPageId: UUID, in transaction: NotesTransaction) throws {
        try transaction.execute(sql: """
            INSERT INTO import_run (id, sourceFingerprint, startedAt, rootPageId, status) VALUES (?, ?, ?, ?, 'running')
            """, arguments: [.text(id.text), .text(fingerprint), Self.value(startedAt), .text(rootPageId.text)])
    }

    func finish(id: UUID, at date: Date, importedPages: Int, simplified: [SimplifiedPage], in transaction: NotesTransaction) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let items = String(decoding: try encoder.encode(simplified), as: UTF8.self)
        try transaction.execute(sql: """
            UPDATE import_run SET status = 'finished', finishedAt = ?, importedPages = ?, simplifiedItems = ? WHERE id = ?
            """, arguments: [Self.value(date), .integer(Int64(importedPages)), .text(items), .text(id.text)])
    }

    func markFailed(id: UUID, at date: Date, in transaction: NotesTransaction) throws {
        try transaction.execute(sql: "UPDATE import_run SET status = 'failed', finishedAt = ? WHERE id = ?",
                                arguments: [Self.value(date), .text(id.text)])
    }

    func all() throws -> [NotionImportRun] {
        try store.database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM import_run ORDER BY startedAt DESC, rowid DESC").map(Self.run)
        }
    }

    func latestFinished(fingerprint: String) throws -> NotionImportRun? {
        try store.database.dbWriter.read { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM import_run WHERE sourceFingerprint = ? AND status = 'finished' ORDER BY startedAt DESC, rowid DESC LIMIT 1
                """, arguments: [fingerprint]).map(Self.run)
        }
    }

    private static func run(_ row: Row) throws -> NotionImportRun {
        guard let id = UUID(uuidString: row["id"]), let status = NotionImportRun.Status(rawValue: row["status"]) else {
            throw NotesStoreError.corruptedRecord("Строка журнала импорта не читается")
        }
        let items: String = row["simplifiedItems"]
        return NotionImportRun(
            id: id, sourceFingerprint: row["sourceFingerprint"], startedAt: row["startedAt"], finishedAt: row["finishedAt"],
            rootPageId: (row["rootPageId"] as String?).flatMap(UUID.init(uuidString:)), importedPages: row["importedPages"],
            simplifiedItems: (try? JSONDecoder().decode([SimplifiedPage].self, from: Data(items.utf8))) ?? [], status: status)
    }

    /// Время так же, как его пишет и читает GRDB.
    private static func value(_ date: Date) -> SQLValue {
        if case .string(let text) = date.databaseValue.storage { return .text(text) }
        return .real(date.timeIntervalSinceReferenceDate)
    }
}

private extension UUID {
    var text: String { uuidString.lowercased() }
}
