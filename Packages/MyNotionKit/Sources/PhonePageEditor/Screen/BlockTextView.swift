#if canImport(UIKit)
import UIKit

/// Поле текста блока или названия страницы. ⌫ в самом начале не стирает знак, а уходит наверх:
/// блок сливается с блоком выше или становится абзацем.
final class BlockTextView: UITextView {
    /// Блок, чей текст сейчас в поле; `nil` — название страницы.
    var blockId: UUID?
    var onBackspaceAtStart: (() -> Void)?
    /// Enter с клавиатуры: новый блок вместо переноса строки.
    var onReturn: (() -> Void)?

    init() {
        super.init(frame: .zero, textContainer: nil)
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        // Оформление приходит только из `InlineText`: вставка — обычным текстом с оформлением места набора.
        allowsEditingTextAttributes = false
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func insertText(_ text: String) {
        if text == "\n", markedTextRange == nil, let onReturn {
            onReturn()
            return
        }
        super.insertText(text)
    }

    override func deleteBackward() {
        if selectedRange == NSRange(location: 0, length: 0), markedTextRange == nil, let onBackspaceAtStart {
            onBackspaceAtStart()
            return
        }
        super.deleteBackward()
    }
}
#endif
