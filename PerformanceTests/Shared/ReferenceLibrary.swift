import Foundation
import NotesCore

/// Эталонная база замеров (research R13): создаётся один раз во временной папке и переиспользуется.
/// v4 — база схемы v7 (003): прежняя v3 (схема v6) при первом запуске мигрировала бы и портила замер запуска;
/// она остаётся для замера миграции эталона (`ReferenceMigrationTests`) и для сборок 002.
enum ReferenceLibrary {
    static func url() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyNotion-reference-library-v4", isDirectory: true)
            .appendingPathComponent("MyNotion.sqlite")
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ReferenceLibraryGenerator().generate(at: url)
        }
        return url
    }
}
