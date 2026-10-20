import Foundation

/// Данные карточки закладки (research R15): заголовок, описание, картинка и значок сайта. Чего нет — пусто.
public struct LinkMetadata: Sendable, Hashable {
    public var url: URL
    public var title: String?
    public var summary: String?
    public var imageURL: URL?
    public var iconURL: URL?

    public init(url: URL, title: String? = nil, summary: String? = nil, imageURL: URL? = nil, iconURL: URL? = nil) {
        self.url = url
        self.title = title
        self.summary = summary
        self.imageURL = imageURL
        self.iconURL = iconURL
    }
}

/// Разбор `<head>` страницы: `og:title|description|image`, `<title>`, `<meta name="description">`, `<link rel="icon">`.
/// Сотня строк без зависимостей вместо веб-движка: LinkPresentation описания не отдаёт (research R15).
public enum HTMLMetadata {
    /// `url` — адрес, с которого пришла страница (после переадресаций): от него считаются относительные адреса.
    public static func parse(_ data: Data, url: URL) -> LinkMetadata {
        let html = head(of: decode(data))
        var meta: [String: String] = [:]
        var icons: [(rel: String, href: String)] = []
        for match in html.matches(of: tagPattern) {
            let name = match.output.1.lowercased()
            let attributes = Self.attributes(String(match.output.2))
            switch name {
            case "meta":
                guard let content = attributes["content"],
                      let key = (attributes["property"] ?? attributes["name"])?.lowercased(), meta[key] == nil else { continue }
                meta[key] = content
            case "link":
                guard let rel = attributes["rel"]?.lowercased(), rel.contains("icon"), let href = attributes["href"] else { continue }
                icons.append((rel, href))
            default:
                break
            }
        }
        let title = html.firstMatch(of: titlePattern).map { String($0.output.1) }

        func clean(_ text: String?) -> String? {
            guard let text else { return nil }
            let collapsed = decodeEntities(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return collapsed.isEmpty ? nil : collapsed
        }
        func resolve(_ href: String?) -> URL? {
            guard let href = clean(href) else { return nil }
            return URL(string: href, relativeTo: url)?.absoluteURL
        }
        // Обычный значок раньше значка для экрана iPhone.
        let icon = icons.first { !$0.rel.contains("apple") } ?? icons.first
        return LinkMetadata(
            url: url,
            title: clean(meta["og:title"]) ?? clean(title) ?? clean(meta["twitter:title"]),
            summary: clean(meta["og:description"]) ?? clean(meta["description"]) ?? clean(meta["twitter:description"]),
            imageURL: resolve(meta["og:image"] ?? meta["og:image:url"] ?? meta["twitter:image"]),
            iconURL: resolve(icon?.href) ?? URL(string: "/favicon.ico", relativeTo: url)?.absoluteURL)
    }

    // MARK: Внутреннее

    nonisolated(unsafe) private static let tagPattern = /<(meta|link)\b([^>]*)>/.ignoresCase()
    nonisolated(unsafe) private static let titlePattern = /<title\b[^>]*>([\s\S]*?)<\/title>/.ignoresCase()
    nonisolated(unsafe) private static let attributePattern = /([A-Za-z_:\-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>\/]+))/

    private static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in text.matches(of: attributePattern) {
            let value = match.output.2 ?? match.output.3 ?? match.output.4 ?? ""
            let key = match.output.1.lowercased()
            if result[key] == nil { result[key] = String(value) }
        }
        return result
    }

    /// Только шапка страницы: `<meta>` в теле — не её описание.
    private static func head(of html: String) -> String {
        if let end = html.range(of: "</head>", options: .caseInsensitive) ?? html.range(of: "<body", options: .caseInsensitive) {
            return String(html[..<end.lowerBound])
        }
        return html
    }

    /// Кодировка — из `charset` страницы; по умолчанию UTF-8, а не прочиталось — Windows-1251 и Latin-1.
    private static func decode(_ data: Data) -> String {
        let prefix = String(decoding: data.prefix(2_048), as: UTF8.self)
        if let match = prefix.firstMatch(of: /charset\s*=\s*["']?([A-Za-z0-9_\-]+)/.ignoresCase()) {
            let name = String(match.output.1) as CFString
            let encoding = CFStringConvertIANACharSetNameToEncoding(name)
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return text
            }
        }
        // Обрезанная на пределе страница может кончаться посреди буквы UTF-8.
        if let text = String(data: data, encoding: .utf8) ?? String(data: data.dropLast(3), encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1251) ?? String(decoding: data, as: UTF8.self)
    }

    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "laquo": "«", "raquo": "»",
                     "mdash": "—", "ndash": "–", "hellip": "…"]
        return text.replacing(/&(#[xX]?[0-9A-Fa-f]+|[A-Za-z]+);/) { match in
            let entity = String(match.output.1)
            if entity.hasPrefix("#") {
                let isHex = entity.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let digits = entity.dropFirst(isHex ? 2 : 1)
                if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) { return String(Character(scalar)) }
                return String(match.output.0)
            }
            return named[entity.lowercased()] ?? String(match.output.0)
        }
    }
}
