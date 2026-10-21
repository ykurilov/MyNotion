import AppKit
import Databases
import NotesCore
import VisualStyle

/// Что получает окно правки ячейки (contracts/database-ui.md, «Щелчок по ячейке выбора, статуса, даты, связи, файлов»):
/// строку, свойство, вид базы и как закрыться. Значение окно читает и пишет само — через операции вида.
@MainActor
public final class CellPopupContext {
    public let controller: DatabaseTableController
    public let rowId: UUID
    public let propertyId: UUID
    /// Первая буква, с которой началась правка (печать по выбранной ячейке): в поле поиска окна.
    public let initialText: String?
    /// Закрыть окно (Esc, выбор в окне выбора).
    public var close: () -> Void = {}
    /// Высота содержимого окна сменилась.
    public var resize: () -> Void = {}

    init(controller: DatabaseTableController, rowId: UUID, propertyId: UUID, initialText: String?) {
        self.controller = controller
        self.rowId = rowId
        self.propertyId = propertyId
        self.initialText = initialText
    }

    public var operations: DatabaseOperations { controller.operations }
    public var store: NotesStore { controller.store }

    /// Свойство и его контекст типа — как сейчас в хранилище (окно живёт дольше правок).
    public func freshContext() -> PropertyContext? {
        guard let catalog = try? DatabaseCatalog.read(controller.databaseId, in: store),
              let property = catalog.propertiesById[propertyId] else { return nil }
        return catalog.context(for: property)
    }

    public func cellValue() -> JSONValue? {
        (try? store.write { try $0.cell(rowId: rowId, propertyId: propertyId)?.value }) ?? nil
    }

    /// Правка, которая не удалась (например, вариант уже удалили с другого Mac), — звуком.
    public func attempt(_ body: () throws -> Void) {
        do { try body() } catch { NSSound.beep() }
    }
}

/// Содержимое окна ячейки: размер карточки и фокус при открытии.
@MainActor
public protocol CellPopupContent: NSView {
    var preferredSize: NSSize { get }
    func focusFirstField()
}

/// Окно правки ячейки типа (research R5, файл на тип): выбор, статус, дата, файлы — US2; связь — US4.
public struct CellPopupFactory: Sendable {
    public let kinds: Set<PropertyKind>
    public let make: @MainActor @Sendable (CellPopupContext) -> any CellPopupContent

    public init(kinds: Set<PropertyKind>, make: @escaping @MainActor @Sendable (CellPopupContext) -> any CellPopupContent) {
        self.kinds = kinds
        self.make = make
    }
}

public enum CellPopups {
    public static var all: [CellPopupFactory] { [OptionPickerView.factory, DateCellView.factory, FilesCellView.factory] }

    public static func factory(for kind: PropertyKind) -> CellPopupFactory? { all.first { $0.kinds.contains(kind) } }
}

/// Карточка окна ячейки под ячейкой, левым краем по ней; одна на приложение — новое окно закрывает прежнее.
@MainActor
final class CellPopupHost {
    static let shared = CellPopupHost()
    private let card = PopupCard()
    private(set) var content: (any CellPopupContent)?
    private var anchor: (rect: NSRect, view: NSView)?
    /// Окно закрылось — сетка снова получает клавиши.
    var onClose: (() -> Void)?

    var isShown: Bool { card.isShown }

    func show(_ content: any CellPopupContent, below rect: NSRect, of view: NSView) {
        card.onClose = nil
        card.close()
        self.content = content
        anchor = (rect, view)
        place()
        card.onClose = { [weak self] in
            self?.content = nil
            self?.onClose?()
        }
        content.focusFirstField()
    }

    /// Размер содержимого сменился — карточка встаёт заново на то же место.
    func resize() {
        guard let content else { return }
        let onClose = card.onClose
        card.onClose = nil
        place()
        card.onClose = onClose
        content.focusFirstField()
    }

    private func place() {
        guard let content, let (rect, view) = anchor, let windowContent = view.window?.contentView else { return }
        // Координаты окна (снизу вверх): окно встаёт левым верхним углом под нижний край ячейки.
        let inWindow = view.convert(rect, to: nil)
        let point = NSPoint(x: inWindow.minX, y: inWindow.minY - Metrics.PopupMenu.anchorSpacing)
        card.show(content, size: content.preferredSize, from: point, in: windowContent)
    }

    func close() { card.close() }
}

// MARK: Общие виды окон US2

/// Список выбора одного из пунктов (форматы числа и даты, знаки после запятой, напоминание, сортировка, цвет): строки
/// с галочкой у текущего, у цвета — образец; сверху — поле фильтра, если пунктов много (`filterPlaceholder`).
@MainActor
final class ChoiceListView: NSView, CellPopupContent {
    struct Item {
        let id: String
        let title: String
        var detail: String? = nil
        var swatch: OptionColor? = nil
    }

    static let rowHeight = PropertyPopupMetrics.rowHeight
    private let items: [Item]
    private let checked: String?
    private var shown: [Item]
    private let filter: PropertyPopupField?
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private var rows: [ChoiceRow] = []
    private let width: CGFloat
    private let maxHeight: CGFloat
    var onChoose: ((String) -> Void)?

    init(items: [Item], checked: String?, width: CGFloat = 240, maxHeight: CGFloat = 360, filterPlaceholder: String? = nil, identifier: String? = nil) {
        self.items = items
        self.checked = checked
        shown = items
        self.width = width
        self.maxHeight = maxHeight
        filter = filterPlaceholder.map { PropertyPopupField(text: "", placeholder: $0, searchGlyph: true, identifier: identifier.map { $0 + "-filter" }) }
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        if let identifier { setAccessibilityIdentifier(identifier) }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        addSubview(scroll)
        if let filter {
            addSubview(filter)
            filter.onChange = { [weak self] text in self?.apply(text) }
            filter.onCommand = { [weak self] selector in
                guard let self else { return false }
                if selector == #selector(NSResponder.insertNewline(_:)), let first = self.shown.first {
                    self.onChoose?(first.id)
                    return true
                }
                return false
            }
        }
        rebuildRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var filterHeight: CGFloat { filter == nil ? 0 : PropertyPopupMetrics.searchBlockHeight }
    private var listHeight: CGFloat { CGFloat(max(shown.count, 1)) * Self.rowHeight + 2 * Metrics.PopupMenu.verticalPadding }

    var preferredSize: NSSize { NSSize(width: width, height: min(maxHeight, filterHeight + listHeight)) }
    override var fittingSize: NSSize { preferredSize }

    func focusFirstField() { filter?.focus() }

    private func apply(_ query: String) {
        let key = query.trimmingCharacters(in: .whitespaces).lowercased()
        shown = key.isEmpty ? items : items.filter { $0.title.lowercased().contains(key) || ($0.detail?.lowercased().contains(key) ?? false) }
        rebuildRows()
        needsLayout = true
    }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = shown.map { item in
            let row = ChoiceRow(item: item, isChecked: item.id == checked)
            row.onPress = { [weak self] in self?.onChoose?(item.id) }
            list.addSubview(row)
            return row
        }
    }

    override func layout() {
        super.layout()
        filter?.frame = NSRect(x: PropertyPopupMetrics.inset, y: 4, width: bounds.width - 2 * PropertyPopupMetrics.inset, height: PropertyPopupMetrics.searchBlockHeight - 4)
        scroll.frame = NSRect(x: 0, y: filterHeight, width: bounds.width, height: bounds.height - filterHeight)
        list.frame = NSRect(x: 0, y: 0, width: bounds.width, height: listHeight)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: PropertyPopupMetrics.inset, y: Metrics.PopupMenu.verticalPadding + CGFloat(index) * Self.rowHeight,
                               width: bounds.width - 2 * PropertyPopupMetrics.inset, height: Self.rowHeight)
        }
    }
}

/// Строка списка окна: образец цвета или значок, название, серое пояснение, галочка у текущего или «›»; подложка под
/// мышью; щелчок — `onPress`.
@MainActor
final class ChoiceRow: NSView {
    let title: String
    var detail: String?
    var icon: String?
    var swatch: OptionColor?
    var isChecked: Bool { didSet { needsDisplay = true } }
    var showsChevron = false
    var isDestructive = false
    var isHighlighted = false { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?

    init(title: String, detail: String? = nil, icon: String? = nil, swatch: OptionColor? = nil, isChecked: Bool = false, identifier: String? = nil) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.swatch = swatch
        self.isChecked = isChecked
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        if isChecked { setAccessibilityValue("выбрано") }
        if let identifier { setAccessibilityIdentifier(identifier) }
    }

    convenience init(item: ChoiceListView.Item, isChecked: Bool) {
        self.init(title: item.title, detail: item.detail, swatch: item.swatch, isChecked: isChecked, identifier: "choice-\(item.id)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let padding = PropertyPopupMetrics.padding
        let height = min(bounds.height, Metrics.ActionMenu.highlightHeight)
        if isHighlighted {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: height), xRadius: Metrics.PopupMenu.rowCornerRadius,
                         yRadius: Metrics.PopupMenu.rowCornerRadius).fill()
        }
        let side = Metrics.PopupMenu.iconSize
        var titleX = padding
        let color = isDestructive ? Palette.destructiveText : Palette.textPrimary
        if let swatch {
            let rect = NSRect(x: padding + 2, y: ((height - 16) / 2).rounded(), width: 16, height: 16)
            Palette.optionChipBackground(swatch.rawValue).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            Palette.border.setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
            titleX = padding + side + Metrics.PopupMenu.iconToTitleSpacing
        } else if let icon {
            ActionMenuIcon.draw(icon, color: color, in: NSRect(x: padding, y: ((height - side) / 2).rounded(), width: side, height: side))
            titleX = padding + side + Metrics.PopupMenu.iconToTitleSpacing
        }
        var end = bounds.maxX - padding
        if isChecked || showsChevron {
            let mark: CGFloat = 16
            let rect = NSRect(x: end - mark, y: ((height - mark) / 2).rounded(), width: mark, height: mark)
            if isChecked {
                ActionMenuIcon.draw("checkmark", color: Palette.textPrimary, in: rect, inkSide: 12)
            } else {
                ActionMenuIcon.drawChevron(in: rect)
            }
            end = rect.minX - 4
        }
        let style = Typography.popupMenuTitle
        if let detail {
            let text = NSAttributedString(string: detail, attributes: [.font: style.font, .foregroundColor: Palette.textSecondary])
            let width = min(text.size().width, (end - titleX) / 2)
            text.draw(in: NSRect(x: end - width, y: (height - style.lineHeight) / 2, width: width, height: style.lineHeight))
            end -= width + padding
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: title, attributes: [.font: style.font, .foregroundColor: color, .paragraphStyle: paragraph])
            .draw(in: NSRect(x: titleX, y: (height - style.lineHeight) / 2, width: max(0, end - titleX), height: style.lineHeight))
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
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// Строка с переключателем справа («Дата окончания», «Включить время», «Показывать число»): синий — включено.
@MainActor
final class PopupToggleRow: NSView {
    let title: String
    var isOn: Bool { didSet { needsDisplay = true; setAccessibilityValue(isOn ? 1 : 0) } }
    var onToggle: ((Bool) -> Void)?
    private var isHovered = false { didSet { needsDisplay = true } }

    init(title: String, isOn: Bool, identifier: String? = nil) {
        self.title = title
        self.isOn = isOn
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        setAccessibilityValue(isOn ? 1 : 0)
        if let identifier { setAccessibilityIdentifier(identifier) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let height = min(bounds.height, Metrics.ActionMenu.highlightHeight)
        if isHovered {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: height), xRadius: Metrics.PopupMenu.rowCornerRadius,
                         yRadius: Metrics.PopupMenu.rowCornerRadius).fill()
        }
        let style = Typography.popupMenuTitle
        NSAttributedString(string: title, attributes: [.font: style.font, .foregroundColor: Palette.textPrimary])
            .draw(in: NSRect(x: PropertyPopupMetrics.padding, y: (height - style.lineHeight) / 2, width: bounds.width - 60, height: style.lineHeight))
        let track = NSRect(x: bounds.maxX - PropertyPopupMetrics.padding - 30, y: ((height - 18) / 2).rounded(), width: 30, height: 18)
        (isOn ? Palette.focusRing : Palette.switchOff).setFill()
        NSBezierPath(roundedRect: track, xRadius: 9, yRadius: 9).fill()
        let knob: CGFloat = 14
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: isOn ? track.maxX - 2 - knob : track.minX + 2, y: track.minY + 2, width: knob, height: knob)).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press()
    }

    func press() {
        isOn.toggle()
        onToggle?(isOn)
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}

/// Вид с началом координат сверху — документ прокрутки списков окон.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Состояния галереи окон ячеек (US2, T074): открытое окно доводится до нужного вида.
@MainActor
public enum CellPopupGallery {
    /// Меню «⋯» первого варианта в окне выбора.
    public static func openOptionMenu() { (CellPopupHost.shared.content as? OptionPickerView)?.showMenuForFirstOption() }

    /// Текст в поиске окна выбора.
    public static func search(_ text: String) { (CellPopupHost.shared.content as? OptionPickerView)?.search(text) }

    /// Подменю «Формат даты» окна даты.
    public static func openDateFormats() { (CellPopupHost.shared.content as? DateCellView)?.showFormats() }

    public static func close() { CellPopupHost.shared.close() }
}
