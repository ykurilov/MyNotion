import Foundation

/// Обложка страницы (data-model.md, «PageCover»): цвет или градиент галереи по id либо своя картинка — файл 002.
/// `offset` — какая часть картинки видна по вертикали, 0…1 (как `cover_position` у Notion).
public struct PageCover: Sendable, Hashable, Codable {
    public enum Source: Sendable, Hashable {
        /// id галереи (contracts/pages-ui.md, «Галерея»); неизвестный id от новой версии хранится как есть.
        case gallery(String)
        case file(AttachmentRef)
    }

    public var source: Source
    public var offset: Double {
        didSet { offset = Self.clamped(offset) }
    }

    public static let defaultOffset = 0.5

    public init(source: Source, offset: Double = PageCover.defaultOffset) {
        self.source = source
        self.offset = Self.clamped(offset)
    }

    /// Файл обложки — ссылка на файл для счётчика ссылок 002.
    public var attachment: AttachmentRef? {
        if case .file(let ref) = source { ref } else { nil }
    }

    static func clamped(_ offset: Double) -> Double {
        offset.isFinite ? min(max(offset, 0), 1) : defaultOffset
    }

    private enum CodingKeys: String, CodingKey { case source, offset }
    private enum SourceKeys: String, CodingKey { case gallery, file }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
        if let ref = try source.decodeIfPresent(AttachmentRef.self, forKey: .file) {
            self.source = .file(ref)
        } else {
            self.source = .gallery(try source.decode(String.self, forKey: .gallery))
        }
        offset = Self.clamped(try container.decodeIfPresent(Double.self, forKey: .offset) ?? Self.defaultOffset)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var source = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
        switch self.source {
        case .gallery(let id): try source.encode(id, forKey: .gallery)
        case .file(let ref): try source.encode(ref, forKey: .file)
        }
        try container.encode(offset, forKey: .offset)
    }
}
