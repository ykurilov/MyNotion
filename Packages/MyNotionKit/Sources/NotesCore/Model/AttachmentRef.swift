import Foundation

/// Описание файла в блоке (data-model.md): уходит на другие Mac в `props`, сам файл — частями через сервер (research R9).
public struct AttachmentRef: Sendable, Hashable, Codable {
    public var id: UUID
    public var name: String
    /// Размер исходника, не больше `maximumByteCount`.
    public var byteCount: Int
    /// Тип UTType, например `public.png`.
    public var contentType: String
    /// SHA-256 исходника, шестнадцатеричной строкой.
    public var sha256: String
    public var partCount: Int

    /// 100 МБ: больше MyNotion не хранит.
    public static let maximumByteCount = 104_857_600
    /// Часть исходника при отправке на сервер — 8 МБ (contracts/sync-and-files-api.md).
    public static let partSize = 8_388_608

    public init(id: UUID = .timeOrdered(), name: String, byteCount: Int, contentType: String, sha256: String) {
        self.id = id
        self.name = name
        self.byteCount = byteCount
        self.contentType = contentType
        self.sha256 = sha256
        partCount = Self.partCount(forByteCount: byteCount)
    }

    /// Частей на файл; у пустого — одна.
    public static func partCount(forByteCount byteCount: Int) -> Int {
        max(1, (byteCount + partSize - 1) / partSize)
    }

    private enum CodingKeys: String, CodingKey { case id, name, byteCount, contentType, sha256, partCount }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        contentType = try container.decode(String.self, forKey: .contentType)
        sha256 = try container.decode(String.self, forKey: .sha256)
        partCount = try container.decode(Int.self, forKey: .partCount)
        guard (0...Self.maximumByteCount).contains(byteCount) else {
            throw DecodingError.dataCorruptedError(forKey: .byteCount, in: container, debugDescription: "Файл больше 100 МБ")
        }
        guard partCount == Self.partCount(forByteCount: byteCount) else {
            throw DecodingError.dataCorruptedError(forKey: .partCount, in: container, debugDescription: "Число частей не сходится с размером")
        }
    }
}
