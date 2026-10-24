import AppKit
import VisualStyle

/// Вопрос перед удалением свойства, как у Notion 7.39 (`notion-delete-property-confirm.png`): текст по центру, под ним
/// во всю ширину кнопки в рамке «Удалить» (красным) и «Отмена». Enter — удалить, Esc — отмена.
@MainActor
final class DeletePropertyConfirmView: NSView {
    private let message = NSTextField(wrappingLabelWithString: "")
    private let confirm: NSButton
    private let cancel: NSButton
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    private static let padding: CGFloat = 12
    private static let buttonHeight: CGFloat = 28
    private static let spacing: CGFloat = 8

    init(question: String) {
        confirm = NSButton(title: "Удалить", target: nil, action: nil)
        cancel = NSButton(title: "Отмена", target: nil, action: nil)
        super.init(frame: .zero)
        message.stringValue = question
        message.alignment = .center
        message.font = .systemFont(ofSize: 14, weight: .medium)
        message.textColor = Palette.textPrimary
        message.setAccessibilityIdentifier("delete-property-question")
        addSubview(message)
        for (button, color, action, identifier) in [(confirm, Palette.destructiveText, #selector(confirmTapped), "delete-property-confirm"),
                                                    (cancel, Palette.textPrimary, #selector(cancelTapped), "delete-property-cancel")] {
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = Metrics.ActionMenu.searchCornerRadius
            button.layer?.borderWidth = 1
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium),
                                                                                           .foregroundColor: color])
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(identifier)
            addSubview(button)
        }
        frame.size = NSSize(width: PropertyPopupMetrics.confirmWidth, height: fittingHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var messageHeight: CGFloat {
        message.preferredMaxLayoutWidth = PropertyPopupMetrics.confirmWidth - 2 * Self.padding
        return ceil(message.intrinsicContentSize.height)
    }

    var fittingHeight: CGFloat { Self.padding * 2 + 4 + messageHeight + Self.spacing + 2 * Self.buttonHeight + Self.spacing }

    override func layout() {
        super.layout()
        let width = bounds.width - 2 * Self.padding
        let height = messageHeight
        message.frame = NSRect(x: Self.padding, y: Self.padding + 4, width: width, height: height)
        confirm.frame = NSRect(x: Self.padding, y: message.frame.maxY + Self.spacing + 4, width: width, height: Self.buttonHeight)
        cancel.frame = NSRect(x: Self.padding, y: confirm.frame.maxY + Self.spacing, width: width, height: Self.buttonHeight)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Рамки кнопок — цветом темы (слой не следует за сменой темы сам).
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for button in [confirm, cancel] { button.layer?.borderColor = Palette.border.cgColor }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: confirmTapped()
        case 53: cancelTapped()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { cancelTapped() }

    @objc private func confirmTapped() { onConfirm?() }
    @objc private func cancelTapped() { onCancel?() }
}
