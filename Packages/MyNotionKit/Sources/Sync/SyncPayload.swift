import AIChatHistory
import Foundation
import NotesCore

/// Содержимое пачки после расшифровки (contracts/sync-api.md, «Содержимое пачки»).
public struct SyncBatch: Sendable, Hashable, Codable {
    /// Растёт при несовместимом изменении. Пачку новее известной версии этот Mac не применяет — она ждёт.
    public var formatVersion: Int
    /// Устройство на сервере, которое отправило пачку.
    public var deviceId: String
    /// Имя Mac — для подписи «вторая версия с …».
    public var deviceName: String
    public var changes: [SyncChange]
    /// Ключи сервисов этого устройства (DeepSeek, Notion) — только внутри зашифрованной пачки. Поле необязательное:
    /// формат прежний, MyNotion без синхронизации ключей его пропускает и применяет остальное.
    public var serviceKeys: [ServiceKeyChange]?
    /// Устройство просит прислать текущие ключи: оно подключилось или обновилось и могло пропустить их в журнале.
    public var requestsServiceKeys: Bool?
    /// Чаты ИИ-агента (008): новые сообщения и заголовки. Необязательное, как ключи: старый MyNotion его пропускает.
    public var aiChats: [AIChatSyncRecord]?
    /// Устройство просит прислать все чаты: оно могло пропустить их, пока было старой версии.
    public var requestsAIChats: Bool?

    /// 2 — блоки 002: поля `placement`, `color`, `props`, новые типы и оформления, сущность `reminder`
    /// (contracts/sync-and-files-api.md). 3 — поля страницы 003: обложка, вид, избранное, открытие, шаблон
    /// (contracts/sync-v3-and-export.md). 4 — базы 004: семь сущностей баз и блок `database`
    /// (contracts/sync-v4-and-export.md). Пачки версий 1–3 читаются.
    public static let currentFormatVersion = 4

    public init(formatVersion: Int = SyncBatch.currentFormatVersion, deviceId: String, deviceName: String,
                changes: [SyncChange], serviceKeys: [ServiceKeyChange]? = nil, requestsServiceKeys: Bool? = nil,
                aiChats: [AIChatSyncRecord]? = nil, requestsAIChats: Bool? = nil) {
        self.formatVersion = formatVersion
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.changes = changes
        self.serviceKeys = serviceKeys
        self.requestsServiceKeys = requestsServiceKeys
        self.aiChats = aiChats
        self.requestsAIChats = requestsAIChats
    }
}

/// Изменение одного поля страницы или блока с меткой часов (research R8).
public struct SyncChange: Sendable, Hashable, Codable {
    public enum Entity: String, Sendable, Hashable, Codable {
        case page
        case block
        /// Отметка «сделано» напоминания; `id` — id упоминания даты (research R11).
        case reminder
        // Формат 4: базы (contracts/sync-v4-and-export.md, «Новые сущности»); `pageId` — страница-база.
        case database
        case property
        case option
        case view
        /// `id` — строка; у каждой ячейки (`value.propertyId`) своя метка.
        case cell
        case relationLink
        case rowOrder

        /// Сущность баз: поле и значение — JSON как в контракте.
        public var isDatabaseRecord: Bool {
            switch self {
            case .page, .block, .reminder: false
            default: true
            }
        }
    }

    public var entity: Entity
    public var id: UUID
    /// Страница блока: по ней блок, которого здесь ещё нет, находит своё место.
    public var pageId: UUID?
    public var value: Value
    public var hlc: HybridTimestamp
    /// Для текста — версия, от которой началась правка; для удаления блока — версия текста, которую видели при удалении.
    public var baseHlc: HybridTimestamp?
    /// Для корзины и стирания — какие правки страницы видел удаливший Mac.
    public var known: ClockKnowledge?
    /// Для места страницы — когда она создана: без этого второй Mac ставит дату первой синхронизации.
    public var createdAt: Date?

    public init(entity: Entity, id: UUID, pageId: UUID? = nil, value: Value, hlc: HybridTimestamp,
                baseHlc: HybridTimestamp? = nil, known: ClockKnowledge? = nil, createdAt: Date? = nil) {
        self.entity = entity
        self.id = id
        self.pageId = pageId
        self.value = value
        self.hlc = hlc
        self.baseHlc = baseHlc
        self.known = known
        self.createdAt = createdAt
    }

    /// Поле и его новое значение.
    public enum Value: Sendable, Hashable {
        // Страница
        case title(String)
        case icon(String?)
        case placement(parentId: UUID?, sortKey: String)
        case trashedAt(Date?)
        /// Стёрта навсегда.
        case erased
        // Страница, формат 3
        case cover(PageCover?)
        case isFullWidth(Bool)
        case isSmallText(Bool)
        /// Ключ порядка в «Избранном» (строка дробного ключа); `nil` — не в избранном.
        case favorite(String?)
        case visitedAt(Date?)
        case isTemplate(Bool)
        // Блок
        case text(InlineText)
        case kindAndIndent(kind: BlockKind, indent: Int, linkedPageId: UUID?)
        case isChecked(Bool)
        /// Место блока: контейнер и порядок одной меткой.
        case blockPlacement(containerId: UUID?, sortKey: String)
        case color(BlockColor)
        case props(BlockProps)
        /// Только из пачек версии 1: порядок без контейнера — контейнер остаётся прежним.
        case sortKey(String)
        case deleted
        /// Юрий выбрал версию: снять «Две версии» с этими вариантами текста на других Mac.
        case conflictResolved(versions: [InlineText])
        // Напоминание
        case doneAt(Date?)
        /// Поле записи базы (формат 4): имя поля и значение JSON (contracts/sync-v4-and-export.md).
        case databaseField(String, JSONValue)

        public var field: String {
            switch self {
            case .title: "title"
            case .icon: "icon"
            case .placement: "placement"
            case .trashedAt: "trashedAt"
            case .erased: "erased"
            case .cover: "cover"
            case .isFullWidth: "isFullWidth"
            case .isSmallText: "isSmallText"
            case .favorite: "favorite"
            case .visitedAt: "visitedAt"
            case .isTemplate: "isTemplate"
            case .text: "text"
            case .kindAndIndent: "kindAndIndent"
            case .isChecked: "isChecked"
            case .blockPlacement: "placement"
            case .color: "color"
            case .props: "props"
            case .sortKey: "sortKey"
            case .deleted: "deleted"
            case .conflictResolved: "conflictResolved"
            case .doneAt: "doneAt"
            case .databaseField(let field, _): field
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case entity, id, pageId, field, value, hlc, baseHlc, known, createdAt }
    private enum PlacementKeys: String, CodingKey { case parentId, sortKey }
    private enum BlockPlacementKeys: String, CodingKey { case containerId, sortKey }
    private enum KindKeys: String, CodingKey { case kind, indent, linkedPageId }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entity = try container.decode(Entity.self, forKey: .entity)
        id = try container.decode(UUID.self, forKey: .id)
        pageId = try container.decodeIfPresent(UUID.self, forKey: .pageId)
        hlc = try container.decode(HybridTimestamp.self, forKey: .hlc)
        baseHlc = try container.decodeIfPresent(HybridTimestamp.self, forKey: .baseHlc)
        known = try container.decodeIfPresent(ClockKnowledge.self, forKey: .known)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        let field = try container.decode(String.self, forKey: .field)
        if entity.isDatabaseRecord {
            value = .databaseField(field, try container.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null)
            return
        }
        switch field {
        case "title": value = .title(try container.decode(String.self, forKey: .value))
        case "icon": value = .icon(try container.decodeIfPresent(String.self, forKey: .value))
        case "placement" where entity == .block:
            let placement = try container.nestedContainer(keyedBy: BlockPlacementKeys.self, forKey: .value)
            value = .blockPlacement(containerId: try placement.decodeIfPresent(UUID.self, forKey: .containerId),
                                    sortKey: try placement.decode(String.self, forKey: .sortKey))
        case "placement":
            let placement = try container.nestedContainer(keyedBy: PlacementKeys.self, forKey: .value)
            value = .placement(parentId: try placement.decodeIfPresent(UUID.self, forKey: .parentId),
                               sortKey: try placement.decode(String.self, forKey: .sortKey))
        case "color": value = .color(try container.decode(BlockColor.self, forKey: .value))
        case "props": value = .props(try container.decode(BlockProps.self, forKey: .value))
        case "doneAt": value = .doneAt(try container.decodeIfPresent(Date.self, forKey: .value))
        case "trashedAt": value = .trashedAt(try container.decodeIfPresent(Date.self, forKey: .value))
        case "erased": value = .erased
        case "cover": value = .cover(try container.decodeIfPresent(PageCover.self, forKey: .value))
        case "isFullWidth": value = .isFullWidth(try container.decode(Bool.self, forKey: .value))
        case "isSmallText": value = .isSmallText(try container.decode(Bool.self, forKey: .value))
        case "favorite": value = .favorite(try container.decodeIfPresent(String.self, forKey: .value))
        case "visitedAt": value = .visitedAt(try container.decodeIfPresent(Date.self, forKey: .value))
        case "isTemplate": value = .isTemplate(try container.decode(Bool.self, forKey: .value))
        case "text": value = .text(try container.decode(InlineText.self, forKey: .value))
        case "kindAndIndent":
            let kind = try container.nestedContainer(keyedBy: KindKeys.self, forKey: .value)
            value = .kindAndIndent(kind: try kind.decode(BlockKind.self, forKey: .kind),
                                   indent: try kind.decode(Int.self, forKey: .indent),
                                   linkedPageId: try kind.decodeIfPresent(UUID.self, forKey: .linkedPageId))
        case "isChecked": value = .isChecked(try container.decode(Bool.self, forKey: .value))
        case "sortKey": value = .sortKey(try container.decode(String.self, forKey: .value))
        case "deleted": value = .deleted
        case "conflictResolved": value = .conflictResolved(versions: try container.decode([InlineText].self, forKey: .value))
        case let unknown:
            throw DecodingError.dataCorruptedError(forKey: .field, in: container, debugDescription: "Неизвестное поле: \(unknown)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entity, forKey: .entity)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(pageId, forKey: .pageId)
        try container.encode(value.field, forKey: .field)
        try container.encode(hlc, forKey: .hlc)
        try container.encodeIfPresent(baseHlc, forKey: .baseHlc)
        try container.encodeIfPresent(known, forKey: .known)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        switch value {
        case .title(let title): try container.encode(title, forKey: .value)
        case .icon(let icon): try container.encode(icon, forKey: .value)
        case .placement(let parentId, let sortKey):
            var placement = container.nestedContainer(keyedBy: PlacementKeys.self, forKey: .value)
            try placement.encode(parentId, forKey: .parentId)
            try placement.encode(sortKey, forKey: .sortKey)
        case .trashedAt(let date): try container.encode(date, forKey: .value)
        case .erased, .deleted: break
        case .cover(let cover): try container.encode(cover, forKey: .value)
        case .isFullWidth(let value), .isSmallText(let value), .isTemplate(let value): try container.encode(value, forKey: .value)
        case .favorite(let key): try container.encode(key, forKey: .value)
        case .visitedAt(let date): try container.encode(date, forKey: .value)
        case .text(let text): try container.encode(text, forKey: .value)
        case .kindAndIndent(let kind, let indent, let linkedPageId):
            var nested = container.nestedContainer(keyedBy: KindKeys.self, forKey: .value)
            try nested.encode(kind, forKey: .kind)
            try nested.encode(indent, forKey: .indent)
            try nested.encode(linkedPageId, forKey: .linkedPageId)
        case .isChecked(let checked): try container.encode(checked, forKey: .value)
        case .blockPlacement(let containerId, let sortKey):
            var placement = container.nestedContainer(keyedBy: BlockPlacementKeys.self, forKey: .value)
            try placement.encode(containerId, forKey: .containerId)
            try placement.encode(sortKey, forKey: .sortKey)
        case .color(let color): try container.encode(color, forKey: .value)
        case .props(let props): try container.encode(props, forKey: .value)
        case .doneAt(let date): try container.encode(date, forKey: .value)
        case .sortKey(let key): try container.encode(key, forKey: .value)
        case .conflictResolved(let versions): try container.encode(versions, forKey: .value)
        case .databaseField(_, let value): try container.encode(value, forKey: .value)
        }
    }
}

/// Как пачки переводятся в байты и обратно: даты — ISO 8601 с долями секунды, ключи по алфавиту.
enum SyncJSON {
    static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(SyncJSON.dateStyle))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: SyncJSON.dateStyle) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Не дата ISO 8601: \(text)")
        }
        return decoder
    }
}
