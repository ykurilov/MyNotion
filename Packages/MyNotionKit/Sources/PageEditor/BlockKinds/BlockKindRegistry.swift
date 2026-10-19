import NotesCore

/// Описатели всех типов блоков по порядку меню «/» (plan.md, Structure Decision).
enum BlockKindRegistry {
    static let all: [BlockKindDescriptor] = [
        .paragraph, .heading1, .heading2, .heading3, .bulletItem, .numberedItem, .checkbox, .pageLink,
        .toggle, .quote, .callout, .divider, .code, .equation, .tableOfContents,
        .image, .file, .video, .bookmark,
        .table, .tableRow, .tableColumn, .tableCell, .columnList, .column,
    ]

    private static let byKind: [BlockKind: BlockKindDescriptor] = Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })

    static func descriptor(for kind: BlockKind) -> BlockKindDescriptor {
        byKind[kind] ?? .notYetBuilt(kind)
    }

    /// Строки меню «/» и «Превратить в».
    static let menuItems: [PopupMenuItem] = all.compactMap(\.menuItem)

    /// Строки только меню «/»: вставка колонок и таблицы.
    static let insertMenuItems: [PopupMenuItem] = all.flatMap(\.insertMenuItems)

    /// Тип по быстрым символам.
    static let shortcutKinds: [String: BlockKind] = Dictionary(all.flatMap { descriptor in
        descriptor.markdownShortcuts.map { ($0, descriptor.kind) }
    }, uniquingKeysWith: { first, _ in first })

    /// Снимки галереи всех типов.
    static var gallerySamples: [BlockGallerySample] { all.flatMap(\.gallerySamples) }
}

extension BlockKind {
    var descriptor: BlockKindDescriptor { BlockKindRegistry.descriptor(for: self) }
}

/// Что приложение и галерея берут из описателей типов.
public enum BlockKinds {
    /// Снимки галереи всех типов, по порядку типов.
    public static var gallerySamples: [BlockGallerySample] { BlockKindRegistry.gallerySamples + InlineAtomGallery.samples }

    /// Части «богатой» страницы от типов, у которых они есть.
    public static var richPageParts: [RichPagePart] {
        BlockKindRegistry.all.compactMap { descriptor in
            descriptor.richPageBlocks.isEmpty ? nil : RichPagePart(name: descriptor.kind.rawValue, blocks: descriptor.richPageBlocks)
        }
    }
}
