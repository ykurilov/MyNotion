import AppKit
import VisualStyle

/// Строка шаблона: иконка (или значок страницы) и название; серая, под курсором и при выборе стрелками — с фоном.
@MainActor
final class TemplateRowView: NSView {
    static let height: CGFloat = 28
    private let iconField = NSTextField(labelWithString: "")
    private let iconImage = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private var isHovered = false { didSet { updateBackground() } }
    var isSelected = false { didSet { updateBackground() } }
    var onClick: (() -> Void)?

    /// `icon == nil` и `symbol == nil` — значок страницы по умолчанию.
    init(title: String, icon: String?, symbol: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 14)
        titleField.textColor = Palette.textSecondary
        titleField.lineBreakMode = .byTruncatingTail
        iconField.font = .systemFont(ofSize: 14)
        iconField.stringValue = icon ?? ""
        iconField.isHidden = icon == nil
        let name = symbol ?? "doc.text"
        iconImage.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        iconImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        iconImage.contentTintColor = Palette.textSecondary
        iconImage.isHidden = icon != nil
        [iconField, iconImage, titleField].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func layout() {
        super.layout()
        let iconBox = NSRect(x: 4, y: (bounds.height - 20) / 2, width: 20, height: 20)
        iconField.sizeToFit()
        iconField.frame = NSRect(x: iconBox.minX + (20 - iconField.frame.width) / 2, y: (bounds.height - iconField.frame.height) / 2,
                                 width: iconField.frame.width, height: iconField.frame.height)
        iconImage.frame = iconBox
        titleField.sizeToFit()
        let x = iconBox.maxX + 6
        titleField.frame = NSRect(x: x, y: (bounds.height - titleField.frame.height) / 2,
                                  width: max(0, bounds.width - x - 4), height: titleField.frame.height)
    }

    private func updateBackground() {
        layer?.backgroundColor = (isHovered || isSelected) ? Palette.hoverBackground.cgColor : nil
    }

    override func updateLayer() { updateBackground() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBackground() }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override var acceptsFirstResponder: Bool { false }
}
