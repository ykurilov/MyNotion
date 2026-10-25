import CryptoKit
import Foundation

// Снимок страницы для ссылки (specs/006-share-link/contracts/share-api.md, «Снимок»): только то, что видно по ссылке.
// Все id — строчными буквами; пустые поля не пишутся. Кодируется с отсортированными ключами: одинаковая страница —
// одинаковые байты и digest.

public struct SharedDocument: Codable, Hashable, Sendable {
    public var version = 1
    public var rootPageId: String
    public var pages: [SharedPage]
    public var files: [SharedFile]

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct SharedPage: Codable, Hashable, Sendable {
    public var id: String
    public var parentId: String?
    public var title: String
    public var icon: String?
    public var cover: SharedCover?
    public var fullWidth: Bool
    public var smallText: Bool
    public var blocks: [SharedBlock]
    public var database: SharedDatabase?
}

public struct SharedCover: Codable, Hashable, Sendable {
    public var file: String?
    public var colors: [String]?
    public var side: Int?
    public var offset: Double
}

public struct SharedBlock: Codable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var indent: Int
    public var container: String?
    public var text: SharedText
    public var checked: Bool?
    public var collapsed: Bool?
    public var color: SharedColor?
    public var props: SharedBlockProps?
    public var page: SharedPageRef?
}

public struct SharedText: Codable, Hashable, Sendable {
    public var string: String
    public var runs: [SharedRun]
}

public struct SharedRun: Codable, Hashable, Sendable {
    public var start: Int
    public var length: Int
    public var style: String
    public var url: String?
    public var color: String?
    /// Упоминание: страница из снимка; `nil` — закрытая.
    public var pageId: String?
    /// Дата — уже текстом.
    public var text: String?
    public var latex: String?
}

public struct SharedColor: Codable, Hashable, Sendable {
    public var text: String?
    public var background: String?
}

public struct SharedBlockProps: Codable, Hashable, Sendable {
    public var icon: String?
    public var language: String?
    public var width: Double?
    public var pixelSize: [Double]?
    public var url: String?
    public var title: String?
    public var description: String?
    public var hasHeaderRow: Bool?
    public var hasHeaderColumn: Bool?
    public var columnId: String?
    public var widthRatio: Double?
    public var videoSource: String?
    public var file: String?
    public var poster: String?
    public var image: String?
    public var iconFile: String?

    var isEmpty: Bool { self == SharedBlockProps() }
}

public struct SharedPageRef: Codable, Hashable, Sendable {
    /// Страница из снимка; `nil` — закрытая.
    public var id: String?
}

public struct SharedDatabase: Codable, Hashable, Sendable {
    public struct Row: Codable, Hashable, Sendable {
        /// Строка открывается, только если её страница в снимке.
        public var pageId: String?
        public var title: String
        public var icon: String?
        public var cells: [String]
    }

    public var columns: [String]
    public var rows: [Row]
}

public struct SharedFile: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var byteCount: Int
}

extension UUID {
    /// Как id в снимке и адресах ссылки.
    var shareKey: String { uuidString.lowercased() }
}
