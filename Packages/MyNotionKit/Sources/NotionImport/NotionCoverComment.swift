import Foundation
import NotesCore

/// Обложка из строки `<!-- mynotion:cover … -->` под названием нашей выгрузки (contracts/sync-v3-and-export.md).
/// Картинка — именем файла в папке страницы; копирует её импорт.
public struct ParsedCover: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        case gallery(String)
        /// Имя файла в папке страницы.
        case file(String)
    }

    public var source: Source
    public var offset: Double

    /// `nil` — это не наш комментарий об обложке.
    static func parse(_ line: String) -> ParsedCover? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->") else { return nil }
        let body = trimmed.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("mynotion:cover ") else { return nil }
        let offset = value(of: "offset", in: body).flatMap(Double.init) ?? PageCover.defaultOffset
        if let id = value(of: "gallery", in: body), !id.isEmpty {
            return ParsedCover(source: .gallery(id), offset: offset)
        }
        if let name = value(of: "file", in: body), !name.isEmpty {
            return ParsedCover(source: .file(name.replacingOccurrences(of: "&quot;", with: "\"")), offset: offset)
        }
        return nil
    }

    /// Значение `name=значение` или `name="значение с пробелами"`.
    private static func value(of name: String, in body: String) -> String? {
        guard let start = body.range(of: " \(name)=") else { return nil }
        let rest = body[start.upperBound...]
        if rest.hasPrefix("\"") {
            let quoted = rest.dropFirst()
            guard let end = quoted.firstIndex(of: "\"") else { return nil }
            return String(quoted[..<end])
        }
        return String(rest.prefix { $0 != " " })
    }
}
