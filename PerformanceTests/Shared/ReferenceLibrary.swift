import Foundation
import NotesCore
import SQLite3

/// Эталонная база замеров (research R13): создаётся один раз во временной папке и переиспользуется.
/// v5 — схема v9 (004): эталон 001–003 и дополнения 004 — базы «Задачи» (10 000 × 30), «Проекты» (500), «Обзор» со
/// встроенной базой (quickstart.md, «Эталон»). Прежние v4 (схема v8, 003) и v3 (схема v6, 002) при первом запуске
/// мигрировали бы и портили замер запуска; они остаются для замера миграции эталона (`ReferenceMigrationTests`).
enum ReferenceLibrary {
    static func url() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyNotion-reference-library-v5", isDirectory: true)
            .appendingPathComponent("MyNotion.sqlite")
        if !FileManager.default.fileExists(atPath: url.path) {
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = folder.appendingPathComponent("base-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: base) }
            try ReferenceLibraryGenerator().generate(at: base)
            try DatabaseSampleGenerator().generate(at: url, base: base)
        }
        try migrate(url)
        return url
    }

    /// Эталон, созданный прошлой схемой (v9 до индекса v10), мигрирует здесь, при подготовке: иначе миграция и копия
    /// базы попали бы в замеренный запуск. Свежий эталон — уже текущей схемы, открытие ничего не меняет.
    static func migrate(_ url: URL) throws {
        try AppDatabase.open(at: url).close()
        try checkpoint(url)
        let folder = url.deletingLastPathComponent()
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.contains(".backup-v") {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Эталон копируют одним файлом, без журнала WAL: всё записанное (миграция, запуски прямо на эталоне) — в основной
    /// файл. Иначе копия выходит прошлой схемы и миграцию делает уже замеренный запуск (T085: индекс v10 жил только в
    /// журнале эталона).
    static func checkpoint(_ url: URL) throws {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard sqlite3_open(url.path, &connection) == SQLITE_OK else { throw CheckpointFailed(path: url.path, code: sqlite3_errcode(connection)) }
        // До первого чтения соединение не знает о журнале: выгрузка вернула бы «не WAL» и ничего не сделала.
        guard sqlite3_exec(connection, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK else {
            throw CheckpointFailed(path: url.path, code: sqlite3_errcode(connection))
        }
        var logFrames: Int32 = 0, checkpointedFrames: Int32 = 0
        let code = sqlite3_wal_checkpoint_v2(connection, nil, SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &checkpointedFrames)
        guard code == SQLITE_OK, logFrames == checkpointedFrames else { throw CheckpointFailed(path: url.path, code: code) }
    }

    struct CheckpointFailed: Error, CustomStringConvertible {
        let path: String
        let code: Int32
        var description: String { "Журнал эталона не выгружен в основной файл (SQLite \(code)): \(path)" }
    }
}
