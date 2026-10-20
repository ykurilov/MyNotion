import Foundation
import GRDB

/// Файл SQLite с записями (research R3): режим WAL, схема ведётся миграциями,
/// перед каждой миграцией рядом кладётся копия базы (конституция, принцип IV).
public final class AppDatabase: Sendable {
    public let url: URL
    package let dbWriter: DatabasePool

    private init(url: URL, dbWriter: DatabasePool) {
        self.url = url
        self.dbWriter = dbWriter
    }

    /// `~/Library/Application Support/MyNotion/MyNotion.sqlite`.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("MyNotion", isDirectory: true)
            .appendingPathComponent("MyNotion.sqlite")
    }

    public static func open(at url: URL = defaultURL, migrations: SchemaMigrations = .current) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        let pool = try DatabasePool(path: url.path, configuration: configuration)

        let migrator = migrations.migrator
        let (isUpToDate, appliedVersions, isSuperseded) = try pool.read { db in
            (try migrator.hasCompletedMigrations(db), try migrator.appliedMigrations(db), try migrator.hasBeenSuperseded(db))
        }
        // Базу записала более новая версия: её схему эта не знает — ни миграций, ни записи (data-model.md, «Схема v6»).
        guard !isSuperseded else {
            try? pool.close()
            throw AppDatabaseError.newerVersion
        }
        if !isUpToDate, let currentVersion = appliedVersions.last {
            try backUp(pool, to: backupURL(for: url, version: currentVersion))
        }
        try migrator.migrate(pool)

        return AppDatabase(url: url, dbWriter: pool)
    }

    /// Версия схемы — последняя применённая миграция.
    public func appliedSchemaVersion() throws -> String? {
        try dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1")
        }
    }

    /// Закрыть соединения; дальше объект не используется.
    public func close() {
        try? dbWriter.close()
    }

    /// `MyNotion.backup-<версия>.sqlite` рядом с базой.
    public static func backupURL(for databaseURL: URL, version: String) -> URL {
        let stem = databaseURL.deletingPathExtension().lastPathComponent
        return databaseURL.deletingLastPathComponent().appendingPathComponent("\(stem).backup-\(version).sqlite")
    }

    /// Вернуть базу из копии. База в это время должна быть закрыта.
    public static func restore(backup backupURL: URL, over databaseURL: URL) throws {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: databaseURL.path + suffix)
            if fileManager.fileExists(atPath: file.path) {
                try fileManager.removeItem(at: file)
            }
        }
        try fileManager.copyItem(at: backupURL, to: databaseURL)
    }

    private static func backUp(_ pool: DatabasePool, to backupURL: URL) throws {
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }
        let copy = try DatabaseQueue(path: backupURL.path)
        try pool.backup(to: copy)
        try copy.close()
    }
}

public enum AppDatabaseError: Error, Equatable, LocalizedError {
    /// База от более новой версии MyNotion.
    case newerVersion

    public var errorDescription: String? {
        switch self {
        case .newerVersion: "База от новой версии MyNotion — обновите приложение"
        }
    }
}
