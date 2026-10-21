import AppKit
import DatabaseGrid
import NotesCore
import VisualStyle

/// Пункт выпадающего списка окна вида: свойство, условие, направление, шаг группы, способ открытия.
struct PanelChoice {
    var title: String
    var caption: String?
    var icon: String?
    /// Плашка варианта вместо текста.
    var chip: OptionColor?
    var isChecked = false
    var isDestructive = false
    var identifier: String?
    var perform: @MainActor () -> Void
}

/// Выпадающий список в карточке: поле поиска (по желанию), пункты с галочкой у текущего, внизу — пункты без поиска
/// («+ Расширенный фильтр»). Стрелки и Enter — из поля поиска; выбор закрывает список.
@MainActor
final class ChoiceMenuView: NSView {
    private let choices: [PanelChoice]
    private let footer: [PanelChoice]
    private let stack = PropertyPopupStack()
    private let search: PropertyPopupField?
    private var rows: [ChoiceRowView] = []
    private var query = ""
    let width: CGFloat
    /// Выбран пункт: список пора закрыть (до действия — действие может открыть другое окно).
    var onChosen: (() -> Void)?
    var onResize: (() -> Void)?
    var onCancel: (() -> Void)?

    init(choices: [PanelChoice], footer: [PanelChoice] = [], searchPlaceholder: String? = nil, width: CGFloat = PanelMetrics.menuWidth,
         identifier: String? = nil) {
        self.choices = choices
        self.footer = footer
        self.width = width
        search = searchPlaceholder.map { PropertyPopupField(text: "", placeholder: $0, searchGlyph: true, identifier: identifier.map { "\($0)-search" }) }
        super.init(frame: .zero)
        if let identifier { setAccessibilityIdentifier(identifier) }
        addSubview(stack)
        search?.onChange = { [weak self] text in
            self?.query = text
            self?.rebuild()
            self?.onResize?()
        }
        search?.onCommand = { [weak self] command in self?.handle(command) ?? false }
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var size: NSSize { NSSize(width: width, height: min(stack.contentHeight, PanelMetrics.maxHeight)) }

    /// Названия видимых пунктов — для проверок.
    var visibleTitles: [String] { rows.map(\.choice.title) }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    func focus() { search?.focus() }

    private func rebuild() {
        stack.removeAll()
        rows = []
        if let search { stack.append(search, height: PropertyPopupMetrics.searchBlockHeight) }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let shown = choices.filter { trimmed.isEmpty || $0.title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        for choice in shown { add(choice) }
        if shown.isEmpty, !trimmed.isEmpty {
            stack.append(PropertyPopupCaption("Ничего не найдено"), height: PropertyPopupMetrics.captionHeight)
        }
        if !footer.isEmpty {
            stack.append(PropertyPopupSeparator(), height: PropertyPopupMetrics.separatorHeight)
            for choice in footer { add(choice) }
        }
        needsLayout = true
    }

    private func add(_ choice: PanelChoice) {
        let row = ChoiceRowView(choice)
        row.onPress = { [weak self] in
            self?.onChosen?()
            choice.perform()
        }
        rows.append(row)
        stack.append(row, height: choice.caption == nil ? PropertyPopupMetrics.rowHeight : 46)
    }

    private func handle(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let delta = command == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let current = rows.firstIndex { $0.isHighlighted }
            let next = current.map { ($0 + delta + rows.count) % rows.count } ?? (delta > 0 ? 0 : rows.count - 1)
            rows.forEach { $0.isHighlighted = false }
            if rows.indices.contains(next) { rows[next].isHighlighted = true }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            (rows.first { $0.isHighlighted } ?? rows.first)?.press()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}

/// Пункт списка: значок, название (или плашка), серое пояснение второй строкой, галочка справа.
@MainActor
final class ChoiceRowView: NSView {
    let choice: PanelChoice
    var onPress: (() -> Void)?
    var isHighlighted = false { didSet { needsDisplay = true } }

    init(_ choice: PanelChoice) {
        self.choice = choice
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(choice.title)
        setAccessibilityValue(choice.isChecked ? 1 : 0)
        if let identifier = choice.identifier { setAccessibilityIdentifier(identifier) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let padding = PropertyPopupMetrics.padding
        let highlight = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 1)
        if isHighlighted {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: highlight, xRadius: Metrics.PopupMenu.rowCornerRadius, yRadius: Metrics.PopupMenu.rowCornerRadius).fill()
        }
        let color = choice.isDestructive ? Palette.destructiveText : Palette.textPrimary
        let style = Typography.popupMenuTitle
        let titleY: CGFloat = choice.caption == nil ? (highlight.height - style.lineHeight) / 2 : 5
        var x = padding
        if let icon = choice.icon {
            ActionMenuIcon.draw(icon, color: color, in: NSRect(x: x, y: titleY, width: 20, height: 20))
            x += 20 + Metrics.PopupMenu.iconToTitleSpacing
        }
        var end = bounds.maxX - padding
        if choice.isChecked {
            ActionMenuIcon.draw("checkmark", color: Palette.textPrimary, in: NSRect(x: end - 14, y: titleY + 3, width: 14, height: 14), inkSide: 12)
            end -= 22
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        if let chip = choice.chip {
            let size = OptionChip.size(for: choice.title)
            OptionChip.draw(title: choice.title, color: chip, in: NSRect(x: x, y: ((highlight.height - size.height) / 2).rounded(),
                                                                         width: min(size.width, end - x), height: size.height))
        } else {
            NSAttributedString(string: choice.title, attributes: [.font: style.font, .foregroundColor: color, .paragraphStyle: paragraph])
                .draw(in: NSRect(x: x, y: titleY, width: max(0, end - x), height: style.lineHeight))
        }
        if let caption = choice.caption {
            NSAttributedString(string: caption, attributes: [.font: PanelMetrics.smallFont, .foregroundColor: Palette.textSecondary, .paragraphStyle: paragraph])
                .draw(in: NSRect(x: x, y: titleY + style.lineHeight + 1, width: max(0, end - x), height: 16))
        }
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

    func press() { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}
