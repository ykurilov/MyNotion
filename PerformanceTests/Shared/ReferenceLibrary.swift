import Foundation
import NotesCore

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
        let folder = url.deletingLastPathComponent()
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.contains(".backup-v") {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
