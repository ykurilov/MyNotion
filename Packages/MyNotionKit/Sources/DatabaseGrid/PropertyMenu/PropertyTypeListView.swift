import AppKit
import NotesCore
import VisualStyle

/// Список типов (contracts/property-types.md, «Список типов»): в окне «+» и «Сменить тип ›» меню колонки — по две колонки,
/// как у Notion 7.39 (`notion-property-types-1.png`); в панели «Изменить свойство» и окне «Свойства» — одной колонкой
/// (`notion-change-property-type-1.png`). Текущий тип отмечен «✓», ID серый, если в базе уже есть. Стрелки двигают
/// подсветку (`PropertyTypePicker.move`), Enter выбирает.
@MainActor
final class PropertyTypeListView: NSView {
    private let columns: Int
    private let current: PropertyKind?
    private let rowsFor: (String) -> [[PropertyTypePicker.Entry]]
    private var rows: [[PropertyTypePicker.Entry]] = []
    private var cells: [(entry: PropertyTypePicker.Entry, view: PropertyPopupRow)] = []
    private var separators: [NSView] = []
    private(set) var highlighted: PropertyKind? { didSet { updateHighlight() } }
    var onChoose: ((PropertyKind) -> Void)?
    /// Высота сменилась (поиск сузил список).
    var onResize: (() -> Void)?

    /// `rows` — строки списка по запросу поиска (`PropertyMenuCommands.typeRows`).
    init(columns: Int, current: PropertyKind?, rows: @escaping (String) -> [[PropertyTypePicker.Entry]]) {
        self.columns = columns
        self.current = current
        rowsFor = rows
        super.init(frame: .zero)
        filter("")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    /// Строки после раскладки: две колонки — как у Notion; одна — каждый тип своей строкой, разделители на месте.
    private func layoutRows(_ source: [[PropertyTypePicker.Entry]]) -> [[PropertyTypePicker.Entry]] {
        columns == 2 ? source : source.flatMap { $0.isEmpty ? [[]] : $0.map { [$0] } }
    }

    func filter(_ query: String) {
        rows = layoutRows(rowsFor(query))
        cells.forEach { $0.view.removeFromSuperview() }
        separators.forEach { $0.removeFromSuperview() }
        cells = []
        separators = []
        for row in rows {
            if row.isEmpty {
                let separator = PropertyPopupSeparator()
                separators.append(separator)
                addSubview(separator)
            }
            for entry in row {
                let view = PropertyPopupRow(title: entry.title, icon: entry.symbol, value: entry.kind == current ? "✓" : nil,
                                            identifier: "property-type-\(entry.kind.rawValue)")
                view.isEnabled = entry.isEnabled
                if !entry.isEnabled { view.toolTip = "В базе уже есть свойство ID" }
                view.onPress = { [weak self] in self?.onChoose?(entry.kind) }
                cells.append((entry, view))
                addSubview(view)
            }
        }
        if let highlighted, !cells.contains(where: { $0.entry.kind == highlighted && $0.entry.isEnabled }) { self.highlighted = nil }
        // Найденное подсвечено сразу: Enter выбирает первый подходящий тип.
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { highlighted = PropertyTypePicker.move(from: nil, .down, in: rows) }
        needsLayout = true
        onResize?()
    }

    var contentHeight: CGFloat {
        rows.reduce(0) { $0 + ($1.isEmpty ? PropertyPopupMetrics.separatorHeight : PropertyPopupMetrics.rowHeight) }
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        var separatorIndex = 0
        var cellIndex = 0
        let width = bounds.width / CGFloat(columns)
        for row in rows {
            if row.isEmpty {
                separators[separatorIndex].frame = NSRect(x: 0, y: y, width: bounds.width, height: PropertyPopupMetrics.separatorHeight)
                separatorIndex += 1
                y += PropertyPopupMetrics.separatorHeight
                continue
            }
            for column in row.indices {
                cells[cellIndex].view.frame = NSRect(x: CGFloat(column) * width, y: y, width: width, height: PropertyPopupMetrics.rowHeight)
                cellIndex += 1
            }
            y += PropertyPopupMetrics.rowHeight
        }
    }

    private func updateHighlight() {
        for cell in cells { cell.view.isHighlighted = cell.entry.kind == highlighted }
    }

    /// Стрелки и Enter из поля над списком; `true` — команда обработана.
    func handle(_ command: Selector) -> Bool {
        let direction: PropertyTypePicker.Direction
        switch command {
        case #selector(NSResponder.moveUp(_:)): direction = .up
        case #selector(NSResponder.moveDown(_:)): direction = .down
        case #selector(NSResponder.moveLeft(_:)) where columns == 2 && highlighted != nil: direction = .left
        case #selector(NSResponder.moveRight(_:)) where columns == 2 && highlighted != nil: direction = .right
        case #selector(NSResponder.insertNewline(_:)):
            guard let highlighted else { return false }
            onChoose?(highlighted)
            return true
        default: return false
        }
        highlighted = PropertyTypePicker.move(from: highlighted, direction, in: rows)
        return true
    }

    /// Названия видимых типов по порядку — для проверок.
    var visibleTitles: [String] { cells.map(\.entry.title) }
}

/// Список типов с полем поиска над ним: поиск сужает список, стрелки и Enter из поля идут в список.
@MainActor
final class PropertyTypeChooserView: NSView {
    let search: PropertyPopupField
    let list: PropertyTypeListView
    private let caption: PropertyPopupCaption?
    var onResize: (() -> Void)?
    /// Esc в поле поиска.
    var onCancel: (() -> Void)?

    init(columns: Int, current: PropertyKind?, caption: String?, rows: @escaping (String) -> [[PropertyTypePicker.Entry]]) {
        search = PropertyPopupField(text: "", placeholder: "Найти тип", searchGlyph: true, identifier: "property-type-search")
        list = PropertyTypeListView(columns: columns, current: current, rows: rows)
        self.caption = caption.map(PropertyPopupCaption.init)
        super.init(frame: .zero)
        if let caption = self.caption { addSubview(caption) }
        addSubview(search)
        addSubview(list)
        search.onChange = { [weak self] query in self?.list.filter(query) }
        search.onCommand = { [weak self] command in
            guard let self else { return false }
            if command == #selector(NSResponder.cancelOperation(_:)) {
                self.onCancel?()
                return true
            }
            return self.list.handle(command)
        }
        list.onResize = { [weak self] in
            self?.needsLayout = true
            self?.onResize?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var contentHeight: CGFloat {
        (caption == nil ? 0 : PropertyPopupMetrics.captionHeight) + PropertyPopupMetrics.searchBlockHeight + list.contentHeight
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        if let caption {
            caption.frame = NSRect(x: 0, y: 0, width: bounds.width, height: PropertyPopupMetrics.captionHeight)
            y += PropertyPopupMetrics.captionHeight
        }
        search.frame = NSRect(x: 0, y: y, width: bounds.width, height: PropertyPopupMetrics.searchBlockHeight)
        y += PropertyPopupMetrics.searchBlockHeight
        list.frame = NSRect(x: 0, y: y, width: bounds.width, height: list.contentHeight)
    }
}
