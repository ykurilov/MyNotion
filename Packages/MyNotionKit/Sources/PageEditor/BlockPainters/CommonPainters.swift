import NotesCore

/// Рисователи для блоков любого типа (например, подложка цвета блока). Свои рисователи типа — в его описателе.
enum BlockPainters {
    static let common: [any BlockPainter] = [BlockBackgroundPainter()]

    /// Рисователи блока: общие, затем его типа.
    static func painters(for kind: BlockKind) -> [any BlockPainter] {
        common + BlockKindRegistry.descriptor(for: kind).painters
    }
}
