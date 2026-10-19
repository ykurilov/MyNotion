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
    /// Ширина, с которой знак разложен в последний раз: по ней редактор ставит вид колонок и таблицы над абзацем.
    private(set) var layoutWidth: CGFloat?

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

    /// `textView` — редактор, в чьём тексте знак: колонкам и таблице для высоты нужен документ.
    func height(forWidth width: CGFloat, in textView: PageTextView? = nil) -> CGFloat {
        nonisolated(unsafe) let attachment = self
        nonisolated(unsafe) let textView = textView
        return MainActor.assumeIsolated {
            BlockViewFactories.shared.factory(for: attachment.block.kind)?
                .height(for: attachment.block, width: width, context: BlockViewContext(textView: textView, width: width)) ?? Self.placeholderHeight
        }
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let width = max(0, proposedLineFragment.width - position.x)
        layoutWidth = width
        nonisolated(unsafe) let container = textContainer
        let textView = MainActor.assumeIsolated { container?.textView as? PageTextView }
        return CGRect(x: 0, y: 0, width: width, height: height(forWidth: width, in: textView))
    }

    /// Без вида (снимок окна, печать) знак ничего не рисует: вид блока — во вложении или у рисователей типа,
    /// а не картинка файла по умолчанию.
    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> NSImage? {
        NSImage(size: NSSize(width: 1, height: 1))
    }

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> NSImage? {
        NSImage(size: NSSize(width: 1, height: 1))
    }

    override func viewProvider(for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = BlockAttachmentViewProvider(textAttachment: self, parentView: parentView,
                                                   textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}
