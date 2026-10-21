import AppKit
import VisualStyle

/// Мерки окон свойства (contracts/database-ui.md): Notion 7.39, снимки 20.10.2026 (1 px ≈ 1,26 pt); «≈» уточняет
/// сверка US1 по живому Notion.
enum PropertyPopupMetrics {
    /// Меню колонки ≈ 220 у Notion; русские названия длиннее — 240.
    static let columnMenuWidth: CGFloat = Metrics.PopupMenu.listMenuWidth
    /// Список типов в две колонки (`notion-property-types-1.png`) ≈ 330, у нас шире под «Множественный выбор».
    static let typeGridWidth: CGFloat = 380
    /// Панель «Изменить свойство» справа на высоту таблицы ≈ 280.
    static let panelWidth: CGFloat = 280
    /// Окно «Свойства» базы и его наибольшая высота.
    static let propertiesWidth: CGFloat = 290
    static let propertiesMaxHeight: CGFloat = 520
    /// Вопрос удаления (`notion-delete-property-confirm.png`) ≈ 260.
    static let confirmWidth: CGFloat = 260
    /// Шапка «← Изменить свойство ×».
    static let headerHeight: CGFloat = 42
    /// Поле имени с иконкой типа: квадрат иконки 28, поле 28, блок 40.
    static let nameBlockHeight: CGFloat = 40
    static let fieldHeight: CGFloat = 28
    /// Поле поиска типа.
    static let searchBlockHeight: CGFloat = 40
    /// Подпись раздела («Тип», «Удалённые свойства»).
    static let captionHeight: CGFloat = 28
    static let rowHeight: CGFloat = Metrics.PopupMenu.compactRowHeight
    static let separatorHeight: CGFloat = Metrics.PopupMenu.groupSeparatorHeight
    static let inset: CGFloat = Metrics.PopupMenu.rowInset
    static let padding: CGFloat = Metrics.PopupMenu.rowHorizontalPadding
}

/// Столбик строк сверху вниз: каждая строка — на всю ширину со своей высотой (окна свойства).
@MainActor
final class PropertyPopupStack: NSView {
    private var rows: [(view: NSView, height: CGFloat, inset: CGFloat)] = []
    var topPadding: CGFloat = Metrics.PopupMenu.verticalPadding
    var bottomPadding: CGFloat = Metrics.PopupMenu.verticalPadding

    override var isFlipped: Bool { true }

    func append(_ view: NSView, height: CGFloat, inset: CGFloat = PropertyPopupMetrics.inset) {
        rows.append((view, height, inset))
        addSubview(view)
        needsLayout = true
    }

    /// Новая высота строки `view` (поиск сузил список) — без пересборки: фокус поля не теряется.
    func setHeight(_ height: CGFloat, of view: NSView) {
        guard let index = rows.firstIndex(where: { $0.view === view }) else { return }
        rows[index].height = height
        needsLayout = true
    }

    func removeAll() {
        rows.forEach { $0.view.removeFromSuperview() }
        rows = []
    }

    var contentHeight: CGFloat { rows.reduce(topPadding + bottomPadding) { $0 + $1.height } }

    override func layout() {
        super.layout()
        var y = topPadding
        for row in rows {
            row.view.frame = NSRect(x: row.inset, y: y, width: max(0, bounds.width - 2 * row.inset), height: row.height)
            y += row.height
        }
    }
}

/// Черта между группами строк.
final class PropertyPopupSeparator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Palette.popupDivider.setFill()
        NSRect(x: PropertyPopupMetrics.padding, y: bounds.midY, width: bounds.width - 2 * PropertyPopupMetrics.padding, height: 1).fill()
    }
}

/// Серая подпись раздела.
final class PropertyPopupCaption: NSView {
    private let text: String
    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let style = Typography.popupMenuSectionHeader
        NSAttributedString(string: text, attributes: [.font: style.font, .foregroundColor: Palette.textSecondary])
            .draw(at: NSPoint(x: PropertyPopupMetrics.padding, y: (bounds.height - style.lineHeight) / 2))
    }
}

/// Строка окна: значок, название, серое значение и «›» справа; подложка под мышью и стрелками; щелчок — `onPress`.
@MainActor
final class PropertyPopupRow: NSView {
    let title: String
    var icon: String?
    var value: String?
    var showsChevron: Bool
    var isDestructive = false
    var isEnabled = true { didSet { needsDisplay = true } }
    var isHighlighted = false { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?

    init(title: String, icon: String?, value: String? = nil, showsChevron: Bool = false, identifier: String? = nil) {
        self.title = title
        self.icon = icon
        self.value = value
        self.showsChevron = showsChevron
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        if let identifier { setAccessibilityIdentifier(identifier) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var itemRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, Metrics.ActionMenu.highlightHeight)) }

    override func draw(_ dirtyRect: NSRect) {
        let padding = PropertyPopupMetrics.padding
        if isHighlighted, isEnabled {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: itemRect, xRadius: Metrics.PopupMenu.rowCornerRadius, yRadius: Metrics.PopupMenu.rowCornerRadius).fill()
        }
        let color = !isEnabled ? Palette.placeholder : isDestructive ? Palette.destructiveText : Palette.textPrimary
        let side = Metrics.PopupMenu.iconSize
        var titleX = padding
        if let icon {
            ActionMenuIcon.draw(icon, color: color, in: NSRect(x: padding, y: ((itemRect.height - side) / 2).rounded(), width: side, height: side))
            titleX = padding + side + Metrics.PopupMenu.iconToTitleSpacing
        }
        var end = bounds.maxX - padding
        if showsChevron {
            let chevron = Metrics.ActionMenu.chevronSize
            let rect = NSRect(x: end - chevron, y: ((itemRect.height - chevron) / 2).rounded(), width: chevron, height: chevron)
            ActionMenuIcon.drawChevron(in: rect)
            end = rect.minX - 4
        }
        let style = Typography.popupMenuTitle
        if let value {
            let text = NSAttributedString(string: value, attributes: [.font: style.font, .foregroundColor: Palette.textSecondary])
            let width = min(text.size().width, (end - titleX) / 2)
            text.draw(in: NSRect(x: end - width, y: (itemRect.height - style.lineHeight) / 2, width: width, height: style.lineHeight))
            end -= width + padding
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: title, attributes: [.font: style.font, .foregroundColor: color, .paragraphStyle: paragraph])
            .draw(in: NSRect(x: titleX, y: (itemRect.height - style.lineHeight) / 2, width: max(0, end - titleX), height: style.lineHeight))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHighlighted = true }
    override func mouseExited(with event: NSEvent) { isHighlighted = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    func press() {
        guard isEnabled else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}

/// Шапка панели и окна: «←» слева, название, «×» справа (`notion-edit-property-number.png`).
@MainActor
final class PropertyPopupHeader: NSView {
    private let title: String
    private let back = NSButton()
    private let close = NSButton()
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?

    init(title: String, showsBack: Bool = true) {
        self.title = title
        super.init(frame: .zero)
        for (button, symbol, label, action) in [(back, "arrow.left", "Назад", #selector(goBack)), (close, "xmark.circle.fill", "Закрыть", #selector(closeTapped))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.contentTintColor = Palette.textSecondary
            button.target = self
            button.action = action
            button.toolTip = label
            addSubview(button)
        }
        back.isHidden = !showsBack
        back.setAccessibilityIdentifier("property-popup-back")
        close.setAccessibilityIdentifier("property-popup-close")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let side: CGFloat = 20
        back.frame = NSRect(x: PropertyPopupMetrics.padding, y: (bounds.height - side) / 2, width: side, height: side)
        close.frame = NSRect(x: bounds.maxX - PropertyPopupMetrics.padding - side, y: (bounds.height - side) / 2, width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let x = back.isHidden ? PropertyPopupMetrics.padding : PropertyPopupMetrics.padding + 28
        NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: Palette.textPrimary])
            .draw(at: NSPoint(x: x, y: (bounds.height - 20) / 2 + 1))
    }

    @objc private func goBack() { onBack?() }
    @objc private func closeTapped() { onClose?() }
}

/// Поле ввода в рамке со скруглением 6 (синяя рамка в фокусе) и необязательным квадратом-значком слева — поле имени
/// свойства с иконкой типа, «Название свойства…», поиск типа. Стрелки, Enter и Esc отдаются `onCommand`.
@MainActor
final class PropertyPopupField: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let icon: String?
    private let showsSearchGlyph: Bool
    /// Команда клавиатуры из поля (`moveUp(_:)`, `insertNewline(_:)`, `cancelOperation(_:)`…); `true` — обработана.
    var onCommand: ((Selector) -> Bool)?
    var onChange: ((String) -> Void)?
    var onEndEditing: ((String) -> Void)?

    init(text: String, placeholder: String, icon: String? = nil, searchGlyph: Bool = false, identifier: String? = nil) {
        self.icon = icon
        showsSearchGlyph = searchGlyph
        super.init(frame: .zero)
        field.stringValue = text
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typography.popupMenuTitle.font
        field.textColor = Palette.textPrimary
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        if let identifier { field.setAccessibilityIdentifier(identifier) }
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var text: String { field.stringValue }

    private var iconBox: NSRect? {
        guard icon != nil else { return nil }
        let side = PropertyPopupMetrics.fieldHeight
        return NSRect(x: PropertyPopupMetrics.padding - PropertyPopupMetrics.inset, y: (bounds.height - side) / 2, width: side, height: side)
    }

    private var box: NSRect {
        let side = PropertyPopupMetrics.fieldHeight
        let x = iconBox.map { $0.maxX + 6 } ?? PropertyPopupMetrics.padding - PropertyPopupMetrics.inset
        return NSRect(x: x, y: (bounds.height - side) / 2, width: bounds.width - x - (PropertyPopupMetrics.padding - PropertyPopupMetrics.inset), height: side)
    }

    var isFocused: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate as? NSTextField === field
    }

    override func layout() {
        super.layout()
        let textX = box.minX + (showsSearchGlyph ? 26 : 8)
        field.frame = NSRect(x: textX, y: box.midY - 10, width: box.maxX - textX - 6, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Metrics.ActionMenu.searchCornerRadius
        if let iconBox, let icon {
            let path = NSBezierPath(roundedRect: iconBox.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            Palette.border.setStroke()
            path.stroke()
            ActionMenuIcon.draw(icon, color: Palette.textSecondary, in: iconBox.insetBy(dx: 4, dy: 4))
        }
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        Palette.emojiSearchBackground.setFill()
        path.fill()
        path.lineWidth = isFocused ? Metrics.ActionMenu.focusRingWidth : 1
        (isFocused ? Palette.focusRing : Palette.searchFieldBorder).setStroke()
        path.stroke()
        if showsSearchGlyph {
            let side = Metrics.ActionMenu.searchIconSize
            ActionMenuIcon.draw("magnifyingglass", color: Palette.textSecondary,
                                in: NSRect(x: box.minX + 6, y: box.midY - side / 2, width: side, height: side), inkSide: side - 2)
        }
    }

    func focus() {
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    func controlTextDidBeginEditing(_ obj: Notification) { needsDisplay = true }
    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }
    func controlTextDidEndEditing(_ obj: Notification) {
        needsDisplay = true
        onEndEditing?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        onCommand?(commandSelector) ?? false
    }
}
