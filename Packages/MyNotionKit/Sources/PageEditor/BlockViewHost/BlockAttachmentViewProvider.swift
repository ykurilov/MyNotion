import AppKit
import NotesCore
import VisualStyle

/// Создаёт вид блока для знака-вложения: вид фабрики типа (`BlockViewFactories`) или заглушку.
final class BlockAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        nonisolated(unsafe) let provider = self
        MainActor.assumeIsolated {
            guard let attachment = provider.textAttachment as? BlockAttachment else { return }
            let textView = provider.textLayoutManager?.textContainer?.textView as? PageTextView
            provider.view = Self.makeHostedView(for: attachment, textView: textView)
        }
    }

    /// Вид блока внутри рамки, которая ловит щелчок: щелчок по виду выделяет блок целиком (режим блоков 001).
    @MainActor
    static func makeHostedView(for attachment: BlockAttachment, textView: PageTextView?) -> BlockAttachmentHostView {
        let width = textView?.textContainer?.size.width ?? 720
        let host = BlockAttachmentHostView(blockId: attachment.blockId, textView: textView)
        host.columnWidth = width
        host.frame = NSRect(x: 0, y: 0, width: width, height: attachment.height(forWidth: width, in: textView))
        let context = BlockViewContext(textView: textView, width: width)
        if let content = BlockViewFactories.shared.factory(for: attachment.block.kind)?.makeView(for: attachment.block, context: context) {
            content.frame = host.bounds
            content.autoresizingMask = [.width, .height]
            host.addSubview(content)
        }
        return host
    }
}

/// Рамка вида блока: щелчок — выделить блок.
final class BlockAttachmentHostView: NSView {
    let blockId: UUID
    weak var textView: PageTextView?
    /// Ширина колонки текста под блоком; вид бывает шире (широкая таблица — до края страницы).
    var columnWidth: CGFloat = 0

    init(blockId: UUID, textView: PageTextView?) {
        self.blockId = blockId
        self.textView = textView
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func mouseDown(with event: NSEvent) {
        guard let textView else { return super.mouseDown(with: event) }
        textView.window?.makeFirstResponder(textView)
        textView.attachmentViewClicked(blockId: blockId)
    }
}

extension PageTextView {
    /// Щелчок по виду блока без текста: блок выделен целиком, как щелчком по «⋮⋮».
    func attachmentViewClicked(blockId: UUID) {
        commitEdits()
        guard let index = document.index(ofBlock: blockId) else { return }
        selectBlocks(index..<index + 1)
    }

    /// Абзац блока-вложения под местом текста: начало абзаца и его конец (начало следующего).
    func attachmentParagraph(at location: Int) -> NSRange? {
        guard let textStorage, location < textStorage.length else { return nil }
        let string = textStorage.string as NSString
        let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
        guard paragraph.length > 0, string.character(at: paragraph.location) == InlineText.objectReplacementCharacter,
              textStorage.attribute(.attachment, at: paragraph.location, effectiveRange: nil) is BlockAttachment else { return nil }
        return paragraph
    }

    /// Курсор внутрь абзаца-вложения не встаёт (research R2): он перешагивает блок в сторону движения — вперёд
    /// в начало следующего блока, назад в конец предыдущего; у края страницы — в другую сторону.
    func caretSkippingAttachments(_ location: Int, from previous: Int) -> Int {
        guard attachmentParagraph(at: location) != nil, let length = textStorage?.length else { return location }
        func step(_ location: Int, forward: Bool) -> Int? {
            var current = location
            while let paragraph = attachmentParagraph(at: current) {
                if forward {
                    // Строка после последнего перевода строки — не блок.
                    guard NSMaxRange(paragraph) < length else { return nil }
                    current = NSMaxRange(paragraph)
                } else {
                    guard paragraph.location > 0 else { return nil }
                    current = paragraph.location - 1
                }
            }
            return current
        }
        let forward = location >= previous
        return step(location, forward: forward) ?? step(location, forward: !forward) ?? location
    }
}
