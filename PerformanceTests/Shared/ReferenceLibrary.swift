import Foundation
import NotesCore

/// Эталонная база замеров (research R13): создаётся один раз во временной папке и переиспользуется.
/// v3 — база схемы v6 (002): прежняя v2 при первом запуске мигрировала бы и портила замер запуска.
enum ReferenceLibrary {
    static func url() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyNotion-reference-library-v3", isDirectory: true)
            .appendingPathComponent("MyNotion.sqlite")
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ReferenceLibraryGenerator().generate(at: url)
        }
        return url
    }
}
