import Foundation

/// Адрес страницы `mynotion://page/<id>`, блока на ней — `mynotion://page/<id>#<blockId>`. Один формат для ссылок внутри
/// страниц, для ссылок агентов (щелчок открывает приложение) и для Mac и iPhone.
public struct PageAddress: Sendable, Hashable {
    public static let scheme = "mynotion"

    public var pageId: UUID
    /// К какому блоку прокрутить; `nil` — к началу страницы.
    public var blockId: UUID?

    public init(pageId: UUID, blockId: UUID? = nil) {
        self.pageId = pageId
        self.blockId = blockId
    }

    /// Не адрес страницы — `nil`. Испорченный id блока не мешает: откроется страница.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == "page" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 1, let pageId = UUID(uuidString: String(parts[0])) else { return nil }
        self.pageId = pageId
        blockId = url.fragment.flatMap(UUID.init(uuidString:))
    }

    public var text: String {
        "\(Self.scheme)://page/\(pageId.uuidString.lowercased())" + (blockId.map { "#\($0.uuidString.lowercased())" } ?? "")
    }

    public var url: URL { URL(string: text)! }
}
