import NotesCore

/// Рисователи для блоков любого типа (например, подложка цвета блока, US2). Свои рисователи типа — в его описателе.
/// Подложка выноски и черта цитаты рисуются и у детей — по поддереву (research R1), поэтому они общие.
enum BlockPainters {
    static let common: [any BlockPainter] = [CalloutBoxPainter(), QuoteBarPainter()]

    /// Рисователи блока: общие, затем его типа.
    static func painters(for kind: BlockKind) -> [any BlockPainter] {
        common + BlockKindRegistry.descriptor(for: kind).painters
    }
}
