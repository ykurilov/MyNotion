import AppKit
import VisualStyle

/// Вопрос перед необратимым действием, как в Notion (contracts/visual-style.md, «Окно корзины»):
/// затемнение над содержимым окна и всеми панелями, заголовок окна со светофором открыт; карточка по центру.
@MainActor
final class ConfirmationDialogWindow: NSWindow {
    let dialog: ConfirmationDialogView
    /// Ответ — один раз: `true` — подтвердили, `false` — отменили.
    var onAnswer: ((Bool) -> Void)?
    private var isAnswered = false
    /// Приложение в фоне — вопрос спрятан, вернулось — снова над окном.
    private var activationObservers: [NSObjectProtocol] = []

    init(title: String, message: String, action: String) {
        dialog = ConfirmationDialogView(title: title, message: message, action: action)
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Выше окна корзины (.floating): корзина затемняется вместе со страницей.
        level = .modalPanel
        isReleasedWhenClosed = false
        contentView = dialog
        dialog.destructiveButton.target = self
        dialog.destructiveButton.action = #selector(confirm)
        dialog.cancelButton.target = self
        dialog.cancelButton.action = #selector(cancel)
        dialog.onClickOutsideCard = { [weak self] in self?.answer(false) }
        setAccessibilityIdentifier("confirmation-dialog")
    }

    /// Показать над окном `parent`; ответ придёт в `onAnswer`. Невидимое окно (модульные проверки) — на экран вопрос
    /// не выходит. Приложение в фоне — вопрос прячется и возвращается вместе с ним: не висит над чужими окнами.
    static func present(over parent: NSWindow, title: String, message: String, action: String,
                        onAnswer: @escaping (Bool) -> Void) {
        let window = ConfirmationDialogWindow(title: title, message: message, action: action)
        window.onAnswer = onAnswer
        window.setFrame(overlayFrame(over: parent), display: false)
        guard PopupWindows.show(window, over: parent, makingKey: true) else { return }
        window.followAppActivation(over: parent)
    }

    /// Не `hidesOnDeactivate`: галерея снимает окна приложения, которое не становится активным.
    private func followAppActivation(over parent: NSWindow) {
        let center = NotificationCenter.default
        activationObservers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.orderOut(nil) }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self, weak parent] _ in
                MainActor.assumeIsolated {
                    guard let self, let parent, !self.isAnswered else { return }
                    PopupWindows.show(self, over: parent, makingKey: true)
                }
            },
        ]
    }

    /// Содержимое окна без заголовка (координаты экрана).
    static func overlayFrame(over parent: NSWindow) -> NSRect {
        parent.convertToScreen(parent.contentLayoutRect)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { answer(false) }

    @objc private func confirm() { answer(true) }
    @objc private func cancel() { answer(false) }

    private func answer(_ confirmed: Bool) {
        guard !isAnswered else { return }
        isAnswered = true
        activationObservers.forEach(NotificationCenter.default.removeObserver)
        activationObservers = []
        parent?.removeChildWindow(self)
        orderOut(nil)
        onAnswer?(confirmed)
    }
}

/// Затемнение и карточка вопроса: заголовок, пояснение, красная кнопка действия и «Отмена» под ней.
@MainActor
final class ConfirmationDialogView: NSView {
    let titleLabel: NSTextField
    let messageLabel: NSTextField
    let destructiveButton: DialogButton
    let cancelButton: DialogButton
    var onClickOutsideCard: (() -> Void)?

    init(title: String, message: String, action: String) {
        titleLabel = Self.label(title, font: .systemFont(ofSize: 14, weight: .semibold), color: Palette.textPrimary)
        messageLabel = Self.label(message, font: .systemFont(ofSize: 14), color: Palette.textSecondary)
        destructiveButton = DialogButton(title: action, fill: Palette.destructiveButtonFill, titleColor: .white)
        cancelButton = DialogButton(title: "Отмена", fill: nil, titleColor: Palette.textPrimary)
        cancelButton.keyEquivalent = "\r"
        destructiveButton.setAccessibilityIdentifier("confirm-destructive")
        super.init(frame: .zero)
        [titleLabel, messageLabel, destructiveButton, cancelButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.alignment = .center
        label.isSelectable = false
        return label
    }

    private var textWidth: CGFloat { Metrics.Confirmation.width - 2 * Metrics.Confirmation.padding }

    private func height(of label: NSTextField) -> CGFloat {
        guard !label.stringValue.isEmpty, let cell = label.cell else { return 0 }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)).height)
    }

    var cardRect: NSRect {
        let metrics = Metrics.Confirmation.self
        let messageHeight = height(of: messageLabel)
        let height = metrics.padding + height(of: titleLabel) + (messageHeight > 0 ? metrics.textSpacing + messageHeight : 0)
            + metrics.buttonsSpacing + 2 * metrics.buttonHeight + metrics.buttonSpacing + metrics.padding
        return NSRect(x: ((bounds.width - metrics.width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(),
                      width: metrics.width, height: height)
    }

    override func layout() {
        super.layout()
        let metrics = Metrics.Confirmation.self
        let card = cardRect
        let x = card.minX + metrics.padding
        var y = card.minY + metrics.padding
        titleLabel.frame = NSRect(x: x, y: y, width: textWidth, height: height(of: titleLabel))
        y = titleLabel.frame.maxY
        let messageHeight = height(of: messageLabel)
        messageLabel.isHidden = messageHeight == 0
        if messageHeight > 0 {
            messageLabel.frame = NSRect(x: x, y: y + metrics.textSpacing, width: textWidth, height: messageHeight)
            y = messageLabel.frame.maxY
        }
        y += metrics.buttonsSpacing
        destructiveButton.frame = NSRect(x: x, y: y, width: textWidth, height: metrics.buttonHeight)
        cancelButton.frame = NSRect(x: x, y: destructiveButton.frame.maxY + metrics.buttonSpacing,
                                    width: textWidth, height: metrics.buttonHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.modalBackdrop.setFill()
        bounds.fill()
        PopupSurface.draw(card: cardRect)
    }

    override func mouseDown(with event: NSEvent) {
        if !cardRect.contains(convert(event.locationInWindow, from: nil)) { onClickOutsideCard?() }
    }
}

/// Кнопка вопроса: залитая (действие) или с рамкой («Отмена»); надпись по центру.
@MainActor
final class DialogButton: NSButton {
    let fill: NSColor?
    let titleColor: NSColor

    init(title: String, fill: NSColor?, titleColor: NSColor) {
        self.fill = fill
        self.titleColor = titleColor
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Metrics.Confirmation.buttonCornerRadius
        if let fill {
            (isHighlighted ? fill.blended(withFraction: 0.15, of: .black) ?? fill : fill).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        } else {
            if isHighlighted {
                Palette.hoverBackground.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
            }
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            Palette.border.setStroke()
            border.lineWidth = 1
            border.stroke()
        }
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: titleColor,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
