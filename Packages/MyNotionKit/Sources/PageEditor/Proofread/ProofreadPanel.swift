import AppKit
import Proofreading
import VisualStyle

/// Что показывает окно «Исправить ошибки».
enum ProofreadPanelState: Equatable {
    case checking
    case corrections([WordDiffPiece])
    case noErrors
    case failed(String)
}

/// Окно правок под выделением: карточка всплывающих окон без рамки, ввод остаётся в тексте страницы
/// (Enter и Esc принимает текст и передаёт сюда).
@MainActor
final class ProofreadPanelWindow: NSPanel {
    let panelView = ProofreadPanelView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        contentView = panelView
        setAccessibilityIdentifier("proofread-panel")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Карточка с местом `card` (координаты экрана).
    func show(card: NSRect, parent: NSWindow) {
        let margin = FormatBarWindow.shadowMargin
        setFrame(card.insetBy(dx: -margin, dy: -margin), display: true)
        PopupWindows.show(self, over: parent)
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

/// Карточка: «Проверяю…» с кругом ожидания, правки (было — зачёркнуто красным, стало — зелёным) или сообщение,
/// под ними кнопки, как в окнах поверх страницы.
@MainActor
final class ProofreadPanelView: NSView {
    private typealias M = Metrics.ProofreadPanel

    var state: ProofreadPanelState = .checking { didSet { if state != oldValue { apply() } } }
    var onReplace: (() -> Void)?
    var onCancel: (() -> Void)?

    private let spinner = NSProgressIndicator()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private let scroll = NSScrollView()
    private let diffView = NSTextView()
    private let cancelButton = ProofreadButtonView(title: "Отмена", isPrimary: false, identifier: "proofread-cancel")
    private let replaceButton = ProofreadButtonView(title: "Заменить", isPrimary: true, identifier: "proofread-replace")
    /// Высота карточки для текущего состояния.
    private(set) var cardHeight: CGFloat = 0

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Исправить ошибки")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.font = .systemFont(ofSize: M.fontSize)
        label.isSelectable = false
        label.setAccessibilityIdentifier("proofread-message")
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: M.fontSize + 2, weight: .regular))
        diffView.isEditable = false
        diffView.isSelectable = false
        diffView.drawsBackground = false
        diffView.textContainerInset = .zero
        diffView.textContainer?.lineFragmentPadding = 0
        diffView.textContainer?.widthTracksTextView = true
        diffView.isVerticallyResizable = true
        diffView.setAccessibilityIdentifier("proofread-diff")
        scroll.documentView = diffView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        cancelButton.onClick = { [weak self] in self?.onCancel?() }
        replaceButton.onClick = { [weak self] in self?.onReplace?() }
        for view in [spinner, label, icon, scroll, cancelButton, replaceButton] as [NSView] { addSubview(view) }
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var card: NSRect {
        let margin = FormatBarWindow.shadowMargin
        return NSRect(x: margin, y: margin, width: M.width, height: cardHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        PopupSurface.draw(card: card)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    /// Состояние → видимые части и их места; высота карточки — по содержимому.
    private func apply() {
        let margin = FormatBarWindow.shadowMargin
        let left = margin + M.padding, contentWidth = M.width - 2 * M.padding
        var y = margin + M.padding
        spinner.stopAnimation(nil)
        for view in [label, icon, scroll, cancelButton, replaceButton] as [NSView] { view.isHidden = true }
        label.textColor = Palette.textPrimary
        cancelButton.title = "Отмена"

        // Ряд кнопок справа; `buttons` — слева направо.
        func buttonsRow(_ buttons: [ProofreadButtonView], at top: CGFloat) {
            var x = left + contentWidth
            for button in buttons.reversed() {
                let width = button.fittingWidth
                x -= width
                button.frame = NSRect(x: x, y: top, width: width, height: M.buttonHeight)
                button.isHidden = false
                x -= M.buttonSpacing
            }
        }
        func line(_ text: String, x: CGFloat, top: CGFloat, width: CGFloat, color: NSColor = Palette.textPrimary) {
            label.stringValue = text
            label.textColor = color
            let height = ceil(label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
            label.frame = NSRect(x: x, y: top + max(0, (M.buttonHeight - height) / 2), width: width, height: height)
            label.isHidden = false
        }

        switch state {
        case .checking:
            spinner.frame = NSRect(x: left, y: y + (M.buttonHeight - 16) / 2, width: 16, height: 16)
            spinner.startAnimation(nil)
            buttonsRow([cancelButton], at: y)
            line("Проверяю…", x: left + 24, top: y, width: cancelButton.frame.minX - left - 32, color: Palette.textSecondary)
            y += M.buttonHeight
        case .noErrors:
            icon.contentTintColor = Palette.notionText(.green)
            icon.frame = NSRect(x: left, y: y + (M.buttonHeight - 18) / 2, width: 18, height: 18)
            icon.isHidden = false
            cancelButton.title = "Готово"
            buttonsRow([cancelButton], at: y)
            line("Ошибок не найдено", x: left + 26, top: y, width: cancelButton.frame.minX - left - 34)
            y += M.buttonHeight
        case .failed(let message):
            cancelButton.title = "Закрыть"
            label.stringValue = message
            label.textColor = Palette.destructiveText
            let height = ceil(label.sizeThatFits(NSSize(width: contentWidth, height: .greatestFiniteMagnitude)).height)
            label.frame = NSRect(x: left, y: y, width: contentWidth, height: height)
            label.isHidden = false
            y += height + M.textToButtonsSpacing
            buttonsRow([cancelButton], at: y)
            y += M.buttonHeight
        case .corrections(let pieces):
            let text = Self.attributedDiff(pieces)
            diffView.textStorage?.setAttributedString(text)
            diffView.setAccessibilityValue(pieces.filter { $0.kind != .removed }.map(\.text).joined())
            let fullHeight = ceil(text.boundingRect(with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
            let height = min(fullHeight, M.maximumTextHeight)
            scroll.frame = NSRect(x: left, y: y, width: contentWidth, height: height)
            diffView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: fullHeight)
            diffView.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
            scroll.isHidden = false
            y += height + M.textToButtonsSpacing
            buttonsRow([cancelButton, replaceButton], at: y)
            y += M.buttonHeight
        }
        cardHeight = y + M.padding - margin
        needsDisplay = true
    }

    /// Размер окна с тенью.
    var fittingCardSize: NSSize { NSSize(width: M.width, height: cardHeight) }

    /// Было — красным и зачёркнуто, стало — зелёным на зелёном фоне, остальное — обычным цветом текста.
    static func attributedDiff(_ pieces: [WordDiffPiece]) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: M.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let result = NSMutableAttributedString()
        for piece in pieces {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph, .foregroundColor: Palette.textPrimary]
            switch piece.kind {
            case .same: break
            case .removed:
                attributes[.foregroundColor] = Palette.notionText(.red)
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = Palette.notionText(.red)
            case .inserted:
                attributes[.foregroundColor] = Palette.notionText(.green)
                attributes[.backgroundColor] = (Palette.notionBackground(.green) ?? .clear)
            }
            result.append(NSAttributedString(string: piece.text, attributes: attributes))
        }
        return result
    }

    // MARK: Для тестов

    var isReplaceVisible: Bool { !replaceButton.isHidden }
    var message: String? { label.isHidden ? nil : label.stringValue }
    func pressReplace() { replaceButton.onClick?() }
    func pressCancel() { cancelButton.onClick?() }
}

/// Кнопка окна правок — как кнопки окон поверх страницы (`ModalCardButtonStyle`): синяя главная, белая с рамкой.
@MainActor
final class ProofreadButtonView: FormatBarControlView {
    var title: String { didSet { setAccessibilityLabel(title); needsDisplay = true } }
    let isPrimary: Bool

    init(title: String, isPrimary: Bool, identifier: String) {
        self.title = title
        self.isPrimary = isPrimary
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityIdentifier(identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: Metrics.ProofreadPanel.fontSize, weight: isPrimary ? .medium : .regular),
         .foregroundColor: isPrimary ? NSColor.white : Palette.textPrimary]
    }

    var fittingWidth: CGFloat {
        ceil(NSAttributedString(string: title, attributes: titleAttributes).size().width) + 2 * Metrics.ProofreadPanel.buttonHorizontalPadding
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Metrics.ProofreadPanel.buttonCornerRadius
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        if isPrimary {
            Palette.primaryButtonFill.withAlphaComponent(isHovered ? 0.88 : 1).setFill()
            shape.fill()
        } else {
            (isHovered ? Palette.hoverBackground : Palette.popupMenuBackground).setFill()
            shape.fill()
            Palette.border.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        let text = NSAttributedString(string: title, attributes: titleAttributes)
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded()))
    }
}
