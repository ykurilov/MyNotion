import NotesCore

/// Рисователи для блоков любого типа (например, подложка цвета блока, US2). Свои рисователи типа — в его описателе.
enum BlockPainters {
    static let common: [any BlockPainter] = []

    /// Рисователи блока: общие, затем его типа.
    static func painters(for kind: BlockKind) -> [any BlockPainter] {
        common + BlockKindRegistry.descriptor(for: kind).painters
    }
}
