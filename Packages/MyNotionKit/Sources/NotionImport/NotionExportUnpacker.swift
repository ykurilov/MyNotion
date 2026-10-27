import CryptoKit
import Foundation

/// Выгрузка, готовая к импорту: папка с деревом страниц и отпечаток содержимого.
public struct PreparedNotionExport: Sendable {
    /// Папка, где лежат страницы выгрузки.
    public let contentRoot: URL
    /// SHA-256 путей и содержимого всех файлов: одна и та же выгрузка — ZIP или распакованная — даёт один отпечаток.
    public let fingerprint: String
    /// Временная папка распаковки; `nil`, если на вход дали уже распакованную папку.
    let temporaryFolder: URL?

    /// Убрать временную папку распаковки.
    public func discard() {
        if let temporaryFolder { try? FileManager.default.removeItem(at: temporaryFolder) }
    }
}

public enum NotionImportError: Error, LocalizedError, Equatable {
    case sourceMissing(String)
    case cannotUnpack(String)
    case notAnExport
    case cannotRead(String)
    case cannotWrite(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path): "Файл «\(path)» не найден."
        case .cannotUnpack(let reason): "Не удалось открыть файл из Notion: \(reason)."
        case .notAnExport: "В выбранном файле нет страниц Notion. В Notion нужен пункт «Export», формат «Markdown & CSV»."
        case .cannotRead(let reason): "Не удалось прочитать файл из Notion: \(reason)."
        case .cannotWrite(let reason): "Страницы не перенесены: \(reason). Прежние записи не тронуты."
        }
    }
}

/// Распаковка ZIP из Notion системной `ditto` во временную папку, включая вложенные ZIP большой выгрузки (T087),
/// и отпечаток содержимого для поиска повторного импорта (FR-027).
public struct NotionExportUnpacker: Sendable {
    public init() {}

    /// ZIP — во временную папку; папка — как есть. Временную папку убирает `PreparedNotionExport.discard()`.
    public func prepare(_ source: URL) throws -> PreparedNotionExport {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw NotionImportError.sourceMissing(source.path)
        }
        if isDirectory.boolValue {
            return PreparedNotionExport(contentRoot: source, fingerprint: try Self.fingerprint(of: source), temporaryFolder: nil)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotion-импорт-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.unzip(source, into: folder)
            // Большая выгрузка Notion — ZIP из частей «ExportBlock-…-Part-N.zip» в корне. ZIP глубже — вложения страниц, их не трогаем.
            for _ in 0..<3 {
                let parts = try Self.visibleEntries(of: folder).filter { $0.pathExtension.lowercased() == "zip" }
                guard !parts.isEmpty else { break }
                for part in parts {
                    try Task.checkCancellation()
                    try Self.unzip(part, into: folder)
                    try FileManager.default.removeItem(at: part)
                }
            }
            return PreparedNotionExport(contentRoot: folder, fingerprint: try Self.fingerprint(of: folder), temporaryFolder: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func unzip(_ archive: URL, into folder: URL) throws {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, folder.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { throw NotionImportError.cannotUnpack(error.localizedDescription) }
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let reason = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NotionImportError.cannotUnpack(reason.isEmpty ? "архив повреждён или это не ZIP" : reason)
        }
        #else
        // На iPhone нет `ditto` и процессов: ZIP из Notion импортируется на Mac.
        throw NotionImportError.cannotUnpack("ZIP из Notion открывается только на Mac")
        #endif
    }

    /// Содержимое папки без служебного: `.DS_Store`, `__MACOSX`, скрытые файлы.
    static func visibleEntries(of folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent != "__MACOSX" }
    }

    /// SHA-256 по всем файлам: путь (в одной форме Юникода — ZIP и диск пишут «ё» по-разному), размер и содержимое.
    static func fingerprint(of folder: URL) throws -> String {
        guard let paths = FileManager.default.subpaths(atPath: folder.path) else {
            throw NotionImportError.cannotRead("папка «\(folder.lastPathComponent)» не читается")
        }
        var hasher = SHA256()
        let files = paths.filter { path in
            let components = path.split(separator: "/")
            guard !components.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        .map { ($0.precomposedStringWithCanonicalMapping, $0) }
        .sorted { $0.0 < $1.0 }
        for (normalized, path) in files {
            try Task.checkCancellation()
            hasher.update(data: Data(normalized.utf8))
            hasher.update(data: Data([0]))
            guard let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent(path)) else {
                throw NotionImportError.cannotRead("файл «\(path)» не читается")
            }
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
