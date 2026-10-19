import AppKit
import NotesCore

/// Знак-вложение абзаца блока без своего текста (research R2): абзац — один U+FFFC и перевод строки.
/// TextKit 2 сам создаёт вид (`BlockAttachmentViewProvider`), когда строка входит в видимую область, и отпускает его
/// за ней; высота строки — высота вида. Проба T005: 50 таких абзацев на 1 000 листаются за 0,3 мс p95, живут только
/// видимые виды, смена высоты перекладывает только свой абзац.
final class BlockAttachment: NSTextAttachment, @unchecked Sendable {
    /// Блок на момент показа абзаца; абзац перерисовывается при каждой правке блока.
    private(set) var block: Block
    var blockId: UUID { block.id }

    /// Высота строки, пока у типа нет своего вида.
    static let placeholderHeight: CGFloat = 13

    init(block: Block) {
        self.block = block
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    /// Тот же блок с новыми полями: вид остаётся, перекладывается только строка.
    func update(_ block: Block) {
        self.block = block
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        nonisolated(unsafe) let attachment = self
        return MainActor.assumeIsolated {
            BlockViewFactories.shared.factory(for: attachment.block.kind)?.height(for: attachment.block, width: width) ?? Self.placeholderHeight
        }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let width = max(0, proposedLineFragment.width - position.x)
        return CGRect(x: 0, y: 0, width: width, height: height(forWidth: width))
    }

    override func viewProvider(for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = BlockAttachmentViewProvider(textAttachment: self, parentView: parentView,
                                                   textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}
