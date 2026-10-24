import ControlProtocol
import Foundation
import NotesCore

/// Чем страница видна в дереве (contracts/block-json.md, `kind`).
public enum PageKind: String, Sendable, Hashable {
    case page, database, row
}

/// Вид страницы, который можно задать JSON: название, иконка, обложка, ширина, размер текста.
public struct PageAppearance: Sendable, Hashable {
    public var title: String
    public var icon: String?
    public var cover: PageCover?
    public var isFullWidth: Bool
    public var isSmallText: Bool

    public init(title: String, icon: String?, cover: PageCover?, isFullWidth: Bool, isSmallText: Bool) {
        self.title = title
        self.icon = icon
        self.cover = cover
        self.isFullWidth = isFullWidth
        self.isSmallText = isSmallText
    }
}

/// Страница в ответах команд (contracts/block-json.md, «Страница»).
public enum PageJSON {
    /// `inTrash` — в корзине сама страница или её предок (по умолчанию — только сама).
    public static func encode(_ page: Page, kind: PageKind, path: [String], hasChildren: Bool, inTrash: Bool? = nil) -> ControlJSON {
        [
            "id": .string(page.id.controlText), "title": .string(page.title), "icon": page.icon.map(ControlJSON.string) ?? .null,
            "kind": .string(kind.rawValue), "parentId": page.parentId.map { .string($0.controlText) } ?? .null,
            "path": .array(path.map(ControlJSON.string)), "hasChildren": .bool(hasChildren),
            "cover": page.cover.map(encode) ?? .null, "fullWidth": .bool(page.isFullWidth), "smallText": .bool(page.isSmallText),
            "isFavorite": .bool(page.favorite != nil), "isTemplate": .bool(page.isTemplate),
            "inTrash": .bool(inTrash ?? (page.trashedAt != nil)),
            "createdAt": .string(page.createdAt.controlText), "updatedAt": .string(page.updatedAt.controlText),
        ]
    }

    /// Узел `page tree`: без обложки и дат, дети — до глубины.
    public static func treeNode(_ page: Page, kind: PageKind, path: [String], hasChildren: Bool, children: [ControlJSON]?) -> ControlJSON {
        var object: [String: ControlJSON] = [
            "id": .string(page.id.controlText), "title": .string(page.title), "icon": page.icon.map(ControlJSON.string) ?? .null,
            "kind": .string(kind.rawValue), "parentId": page.parentId.map { .string($0.controlText) } ?? .null,
            "path": .array(path.map(ControlJSON.string)), "hasChildren": .bool(hasChildren),
        ]
        if let children { object["children"] = .array(children) }
        return .object(object)
    }

    public static func encode(_ cover: PageCover) -> ControlJSON {
        let offset = ControlJSON.number(cover.offset)
        switch cover.source {
        case .gallery(let id): return ["gallery": .string(id), "offset": offset]
        case .file(let ref): return ["attachmentId": .string(ref.id.controlText), "name": .string(ref.name), "offset": offset]
        case .unknown(let raw): return ["unknown": raw.control, "offset": offset]
        }
    }

    /// `null` — без обложки.
    public static func cover(_ json: ControlJSON, attachments: AttachmentLookup) throws(ControlError) -> PageCover? {
        if json.isNull { return nil }
        let offset = json["offset"]?.number ?? PageCover.defaultOffset
        if let gallery = json["gallery"]?.string { return PageCover(source: .gallery(gallery), offset: offset) }
        if let text = json["attachmentId"]?.string {
            guard let id = UUID(uuidString: text), let ref = attachments(id) else {
                throw ControlError(.attachmentNotFound, "Нет вложения \(text)", hint: "Сначала добавьте файл: mynotion attachment add",
                                   details: ["attachmentId": .string(text)])
            }
            return PageCover(source: .file(ref), offset: offset)
        }
        throw ControlError(.invalidValue, "Обложка — {\"gallery\": …}, {\"attachmentId\": …} или null",
                           hint: #"Пример: {"gallery":"gradient-3","offset":0.5}"#, details: ["argument": "cover"])
    }

    public static func appearance(_ json: ControlJSON, attachments: AttachmentLookup) throws(ControlError) -> PageAppearance {
        guard let title = json["title"]?.string else {
            throw ControlError(.invalidValue, "Нужно название `title`", details: ["argument": "title"])
        }
        return PageAppearance(title: title, icon: json["icon"]?.string, cover: try cover(json["cover"] ?? .null, attachments: attachments),
                              isFullWidth: json["fullWidth"]?.bool ?? false, isSmallText: json["smallText"]?.bool ?? false)
    }
}
