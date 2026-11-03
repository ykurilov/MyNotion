import AppKit
import Databases
import NotesCore
import VisualStyle

/// Поле поиска в строке вида (contracts/database-ui.md, «Поиск в базе»): лупа, текст, «×» — очистить и свернуть.
@MainActor
public final class ViewBarSearchField: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 200
    let field = NSTextField()
    private let clear = NSButton()
    var onChange: ((String) -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("database-search")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.placeholderString = "Введите для поиска…"
        field.delegate = self
        field.setAccessibilityIdentifier("database-search-field")
        addSubview(field)
        clear.isBordered = false
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Очистить поиск")
        clear.contentTintColor = Palette.textSecondary
        clear.target = self
        clear.action = #selector(close)
        clear.setAccessibilityIdentifier("database-search-clear")
        addSubview(clear)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public override var isFlipped: Bool { true }

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    func focus() { window?.makeFirstResponder(field) }

    public override func layout() {
        super.layout()
        field.frame = NSRect(x: 24, y: (bounds.height - 18) / 2, width: bounds.width - 48, height: 18)
        clear.frame = NSRect(x: bounds.width - 22, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular).applying(.init(paletteColors: [Palette.textSecondary]))
        NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)?
            .draw(in: NSRect(x: 4, y: (bounds.height - 14) / 2, width: 14, height: 14))
    }

    public func controlTextDidChange(_ notification: Notification) { onChange?(field.stringValue) }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        close()
        return true
    }

    @objc private func close() { onClose?() }
}

/// Плашка полосы под строкой вида.
public enum ViewChip: Sendable, Hashable {
    /// Простой фильтр — путь в корне дерева.
    case filter(FilterPath)
    /// Расширенный фильтр — путь его группы.
    case advanced(FilterPath)
    case sorts
    case addFilter
}

/// Полоса фильтров и сортировки (contracts/database-ui.md): «[Статус: не Готово ▾] [⇅ 2 сортировки ▾] [+ Фильтр]».
/// Показывается после правки фильтра или сортировки и прячется при новом открытии базы (как у Notion).
@MainActor
public final class ViewChipsBar: NSView {
    public static let height: CGFloat = 36
    public var onChip: ((ViewChip, NSView) -> Void)?
    private var chipViews: [ViewChipView] = []

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("database-chips-bar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public override var isFlipped: Bool { true }

    /// Плашки по виду: условия корня фильтра, расширенный фильтр, сортировка, «+ Фильтр».
    public func update(view: DatabaseView, catalog: DatabaseCatalog) {
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews = Self.chips(view: view, catalog: catalog).map { chip in
            let chipView = ViewChipView(title: chip.title, symbol: chip.symbol, style: chip.style)
            chipView.setAccessibilityIdentifier(chip.identifier)
            chipView.onPress = { [weak self, weak chipView] in
                guard let self, let chipView else { return }
                onChip?(chip.chip, chipView)
            }
            return chipView
        }
        chipViews.forEach(addSubview)
        needsLayout = true
    }

    struct Chip {
        let chip: ViewChip
        let title: String
        let symbol: String?
        let style: ViewChipView.Style
        let identifier: String
    }

    static func chips(view: DatabaseView, catalog: DatabaseCatalog) -> [Chip] {
        var chips: [Chip] = []
        for (index, node) in FilterEditing.root(view.filterNode).children.enumerated() {
            if node.isGroup {
                chips.append(Chip(chip: .advanced([index]), title: FilterTexts.rules(node.ruleCount), symbol: "line.3.horizontal.decrease",
                                  style: .active, identifier: "database-chip-advanced"))
            } else if let condition = node.condition {
                let (text, active) = FilterTexts.chipText(condition, catalog: catalog)
                chips.append(Chip(chip: .filter([index]), title: text, symbol: nil, style: active ? .active : .plain,
                                  identifier: "database-chip-filter"))
            }
        }
        let sorts = view.sortSpecs.filter { catalog.propertiesById[$0.propertyId] != nil }
        if let first = sorts.first {
            let title = sorts.count == 1 ? catalog.propertiesById[first.propertyId]!.name : FilterTexts.sorts(sorts.count)
            let symbol = sorts.count == 1 ? (first.ascending ? "arrow.up" : "arrow.down") : "arrow.up.arrow.down"
            chips.append(Chip(chip: .sorts, title: title, symbol: symbol, style: .active, identifier: "database-chip-sorts"))
        }
        chips.append(Chip(chip: .addFilter, title: "Фильтр", symbol: "plus", style: .add, identifier: "database-chip-add-filter"))
        return chips
    }

    public override func layout() {
        super.layout()
        var x: CGFloat = 0
        for chip in chipViews {
            let width = min(chip.fittingWidth, 320)
            chip.frame = NSRect(x: x, y: (bounds.height - 26) / 2, width: width, height: 26)
            x += width + 6
        }
    }
}

/// Плашка: синяя (фильтр со значением, сортировка), серая (фильтр без значения), «+ Фильтр» без рамки.
@MainActor
final class ViewChipView: NSView {
    enum Style { case active, plain, add }
    let title: String
    let symbol: String?
    let style: Style
    var onPress: (() -> Void)?
    private let font = NSFont.systemFont(ofSize: 13, weight: .medium)

    init(title: String, symbol: String?, style: Style) {
        self.title = title
        self.symbol = symbol
        self.style = style
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var fittingWidth: CGFloat {
        let text = (title as NSString).size(withAttributes: [.font: font]).width
        return 10 + (symbol == nil ? 0 : 18) + ceil(text) + (style == .add ? 8 : 24)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = switch style {
        case .active: Palette.activeViewControl
        case .plain, .add: Palette.textSecondary
        }
        if style != .add {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 13, yRadius: 13)
            (style == .active ? Palette.activeViewControl.withAlphaComponent(0.2) : Palette.hoverBackground).setFill()
            path.fill()
            // У Notion активная плашка — полупрозрачная заливка без рамки.
            if style != .active {
                Palette.border.setStroke()
                path.stroke()
            }
        }
        var x: CGFloat = 10
        if let symbol {
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [color]))
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)?
                .draw(in: NSRect(x: x, y: (bounds.height - 13) / 2, width: 13, height: 13))
            x += 18
        }
        let string = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        let available = bounds.width - x - (style == .add ? 4 : 22)
        string.draw(with: NSRect(x: x, y: (bounds.height - size.height) / 2, width: available, height: size.height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if style != .add {
            let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [color]))
            NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)?
                .draw(in: NSRect(x: bounds.width - 18, y: (bounds.height - 9) / 2, width: 10, height: 9))
        }
    }
}
