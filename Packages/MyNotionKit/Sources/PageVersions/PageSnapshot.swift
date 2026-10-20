import Foundation
import NotesCore

/// Снимок страницы для версии (data-model.md, «PageSnapshot»): поля страницы и все её блоки всех потоков в формате записи 002.
/// В базе — JSON, сжатый LZFSE. Снимок читается сам по себе: восстановление не проходит цепочку версий (research R11).
public struct PageSnapshot: Sendable, Hashable, Codable {
    public static let currentVersion = 1

    public var snapshotVersion: Int
    public var title: String
    public var icon: String?
    public var cover: PageCover?
    public var isFullWidth: Bool
    public var isSmallText: Bool
    public var blocks: [SnapshotBlock]

    public init(page: Page, blocks: [Block]) {
        snapshotVersion = Self.currentVersion
        title = page.title
        icon = page.icon
        cover = page.cover
        isFullWidth = page.isFullWidth
        isSmallText = page.isSmallText
        self.blocks = blocks.map(SnapshotBlock.init)
    }

    /// Разобрать сжатый снимок; снимок более новой версии формата — ошибка, а не пустая страница.
    public init(compressed data: Data) throws {
        let json = try (data as NSData).decompressed(using: .lzfse) as Data
        let version = try JSONDecoder().decode(FormatProbe.self, from: json).snapshotVersion
        guard version <= Self.currentVersion else { throw PageSnapshotError.newerFormat(version) }
        self = try JSONDecoder().decode(Self.self, from: json)
    }

    public func compressed() throws -> Data {
        try (JSONEncoder().encode(self) as NSData).compressed(using: .lzfse) as Data
    }

    /// Блоки снимка на странице `pageId`, по порядку записи.
    public func blocks(onPage pageId: UUID) -> [Block] {
        blocks.map { $0.block(onPage: pageId) }
    }

    /// Страница в виде версии: поля снимка поверх текущей записи (место в дереве, корзина, избранное — как сейчас).
    public func applied(to page: Page) -> Page {
        var page = page
        page.title = title
        page.icon = icon
        page.cover = cover
        page.isFullWidth = isFullWidth
        page.isSmallText = isSmallText
        return page
    }

    /// Что вернуть восстановлением (`PageTreeOperations.restoreVersion`).
    public func restoreTarget(pageId: UUID) -> PageRestoreTarget {
        PageRestoreTarget(title: title, icon: icon, cover: cover, isFullWidth: isFullWidth, isSmallText: isSmallText,
                          blocks: blocks(onPage: pageId))
    }

    private struct FormatProbe: Decodable {
        let snapshotVersion: Int
    }
}

/// Блок снимка: все поля записи блока, кроме меток часов (они у восстановления новые).
public struct SnapshotBlock: Sendable, Hashable, Codable {
    public var id: UUID
    public var kind: BlockKind
    public var text: InlineText
    public var indent: Int
    public var isChecked: Bool
    public var linkedPageId: UUID?
    public var sortKey: FractionalSortKey
    public var containerId: UUID?
    public var color: BlockColor
    public var props: BlockProps

    init(_ block: Block) {
        id = block.id
        kind = block.kind
        text = block.text
        indent = block.indent
        isChecked = block.isChecked
        linkedPageId = block.linkedPageId
        sortKey = block.sortKey
        containerId = block.containerId
        color = block.color
        props = block.props
    }

    func block(onPage pageId: UUID) -> Block {
        Block(id: id, pageId: pageId, kind: kind, text: text, indent: indent, isChecked: isChecked, linkedPageId: linkedPageId,
              sortKey: sortKey, containerId: containerId, color: color, props: props)
    }

    /// Содержимое и место те же (метки часов не в счёт).
    func hasSameContent(as other: SnapshotBlock) -> Bool { self == other }
}

public enum PageSnapshotError: Error, Equatable, LocalizedError {
    case newerFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .newerFormat: "Версию записала более новая версия MyNotion — обновите приложение"
        }
    }
}
