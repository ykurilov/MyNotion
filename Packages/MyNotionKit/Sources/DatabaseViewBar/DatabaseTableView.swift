import AppKit
import DatabaseGrid
import Databases
import NotesCore
import VisualStyle

/// База в странице (US1): встроенная — серое название, строка вида, сетка по пределу загрузки и «Загрузить ещё»;
/// на всю страницу — строка вида и сетка со своей прокруткой (название — шапка страницы). Отмеченные строки —
/// полоса «N выбрано» вместо строки вида.
@MainActor
public final class DatabaseTableView: NSView, NSTextFieldDelegate {
    public enum Mode: Sendable { case inline, page }

    /// Что открыть хозяину: окна вида (`ViewPanels`).
    public enum ViewCommand: Sendable, Hashable {
        case addFilter
        case filter(FilterPath)
        case sorts
        case settings(selectName: Bool)
    }

    public let controller: DatabaseTableController
    public let mode: Mode
    public let grid: DatabaseGridView
    public let viewBar = ViewBarView()
    public let chipsBar = ViewChipsBar()
    /// Полоса плашек показана: после правки фильтра или сортировки в этом окне; при новом открытии базы — нет (Notion).
    public private(set) var showsChips = false
    private var lastFilterAndSorts: (JSONValue?, JSONValue)?
    let titleField = NSTextField()
    let loadMoreButton = NSButton()
    let selectionBar = RowSelectionBar()
    private let rowMenu = RowMenuPresenter()
    private let tabMenuCard = PopupCard()

    /// Высота сменилась (строки, «Загрузить ещё»): хозяин перекладывает строку блока.
    public var onHeightChange: (() -> Void)?
    /// Меню колонки, «+» и «•••» шапки — окна свойств (хозяин подключает `PropertyMenuPresenter`).
    public var onColumnMenu: ((DatabaseProperty, NSRect, NSView) -> Void)?
    public var onAddProperty: ((NSRect, NSView) -> Void)?
    public var onViewSettings: ((NSRect, NSView) -> Void)?
    /// Окна вида (US3): хозяин открывает `ViewPanels` у кнопки или плашки (`rect` — в координатах `view`).
    public var onViewCommand: ((ViewCommand, NSRect, NSView) -> Void)?
    /// Открыт другой вид (вкладка, новый, копия): окна свойств хозяина переключаются на него.
    public var onViewSwitch: ((UUID) -> Void)?
    /// ⤢ у встроенной базы: открыть её на всё окно.
    public var onOpenAsPage: (() -> Void)?
    /// Действия меню строки, которые даёт окно.
    public var rowMenuActions = RowMenuActions()
    /// Подписка хозяина (размер окна у базы на всю страницу): снимается вместе с видом.
    public var hostState: (any NSObjectProtocol)?

    static let titleHeight: CGFloat = 42
    static let loadMoreHeight: CGFloat = 34

    public init(controller: DatabaseTableController, mode: Mode) {
        self.controller = controller
        self.mode = mode
        // И на всю страницу таблица — часть страницы: листается страница, название уезжает, шапка колонок липнет (Notion).
        grid = DatabaseGridView(controller: controller, scrollsVertically: false)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("База данных")
        setAccessibilityIdentifier(mode == .inline ? "database-inline" : "database-page")
        if mode == .inline {
            titleField.font = .systemFont(ofSize: 20, weight: .bold)
            titleField.textColor = Palette.textPrimary
            titleField.placeholderAttributedString = NSAttributedString(string: "Новая база", attributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: Palette.textSecondary,
            ])
            titleField.isBordered = false
            titleField.drawsBackground = false
            titleField.focusRingType = .none
            titleField.delegate = self
            titleField.stringValue = controller.title
            titleField.setAccessibilityIdentifier("database-inline-title")
            addSubview(titleField)
        }
        viewBar.isInline = mode == .inline
        addSubview(viewBar)
        chipsBar.isHidden = true
        addSubview(chipsBar)
        addSubview(grid)
        loadMoreButton.isBordered = false
        loadMoreButton.attributedTitle = NSAttributedString(string: "Загрузить ещё", attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: Palette.textSecondary,
        ])
        loadMoreButton.alignment = .left
        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMore)
        loadMoreButton.setAccessibilityIdentifier("database-load-more")
        addSubview(loadMoreButton)
        selectionBar.isHidden = true
        addSubview(selectionBar)
        wire()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    isolated deinit {
        if let hostState { NotificationCenter.default.removeObserver(hostState) }
    }

    public override var isFlipped: Bool { true }

    private func wire() {
        controller.onReload = { [weak self] in self?.refresh() }
        controller.onRowsChange = { [weak self] rows in
            for row in rows { self?.grid.redrawRow(row) }
        }
        grid.onColumnMenu = { [weak self] property, rect in
            guard let self else { return }
            onColumnMenu?(property, convert(rect, from: grid), self)
        }
        grid.onAddProperty = { [weak self] rect in
            guard let self else { return }
            onAddProperty?(convert(rect, from: grid), self)
        }
        grid.onViewSettings = { [weak self] rect in
            guard let self else { return }
            onViewSettings?(convert(rect, from: grid), self)
        }
        grid.onRowMenu = { [weak self] row, point in
            guard let self else { return }
            let rows = grid.selectedRows.contains(row) ? grid.selectedRows.sorted() : [row]
            rowMenu.show(rows: rows, of: grid, at: point, actions: rowMenuActions)
        }
        grid.onRowSelectionChange = { [weak self] rows in self?.rowSelectionChanged(rows) }
        controller.onTotalsChange = { [weak self] in
            guard let self else { return }
            grid.totals = controller.totals
        }
        grid.onGroupToggle = { [weak self] key in self?.controller.toggleGroup(key) }
        grid.onHeightChange = { [weak self] in
            self?.needsLayout = true
            self?.onHeightChange?()
        }
        selectionBar.onDuplicate = { [weak self] in
            guard let self else { return }
            controller.duplicateRows(grid.selectedRows.sorted())
            grid.clearSelection()
        }
        selectionBar.onTrash = { [weak self] in
            guard let self else { return }
            controller.trashRows(grid.selectedRows.sorted())
            grid.clearSelection()
        }
        selectionBar.onMore = { [weak self] anchor in
            guard let self, let first = grid.selectedRows.min() else { return }
            rowMenu.show(rows: grid.selectedRows.sorted(), of: grid, at: grid.convert(NSPoint(x: anchor.frame.minX, y: anchor.frame.maxY), from: anchor.superview),
                         actions: rowMenuActions)
            _ = first
        }
        var actions: [ViewBarSlot: (NSView) -> Void] = [
            .create: { [weak self] _ in self?.createRowAtTop() },
            .filter: { [weak self] button in self?.filterPressed(button) },
            .sort: { [weak self] button in self?.command(.sorts, from: button) },
            .search: { [weak self] _ in
                self?.viewBar.setSearching(true)
                self?.controller.prepareSearch()
            },
            .settings: { [weak self] button in self?.command(.settings(selectName: false), from: button) },
        ]
        if mode == .inline { actions[.openFullPage] = { [weak self] _ in self?.onOpenAsPage?() } }
        viewBar.onSearchChange = { [weak self] text in self?.controller.setSearch(text) }
        viewBar.onSelectTab = { [weak self] id in self?.switchView(to: id) }
        viewBar.onTabMenu = { [weak self] id, tab in self?.showTabMenu(id, from: tab) }
        viewBar.onAddView = { [weak self] _ in self?.addView() }
        viewBar.actions = actions
        chipsBar.onChip = { [weak self] chip, view in
            guard let self else { return }
            switch chip {
            case .filter(let path), .advanced(let path): command(.filter(path), from: view)
            case .sorts: command(.sorts, from: view)
            case .addFilter: command(.addFilter, from: view)
            }
        }
    }

    /// Строки или колонки сменились: перерисовать, у встроенной — пересчитать высоту.
    public func refresh() {
        let tabs = (try? ViewQuery.views(of: controller.databaseId, in: controller.store))?.map { ViewBarView.Tab(id: $0.id, name: $0.name) } ?? []
        // Вкладки пересобираются, только когда виды сменились (перечитывание таблицы — на каждую правку).
        if tabs != viewBar.tabs { viewBar.tabs = tabs }
        viewBar.activeTabId = controller.viewId
        // У встроенной базы с одним видом вкладки не видно (Notion 7.39).
        viewBar.showsTabs = !(mode == .inline && viewBar.tabs.count <= 1)
        if mode == .inline, titleField.currentEditor() == nil { titleField.stringValue = controller.title }
        loadMoreButton.isHidden = !controller.hasMoreRows
        updateViewControls()
        grid.groupSections = controller.sections
        grid.showsNewGroup = controller.view.groupSettings.flatMap { controller.catalog.propertiesById[$0.propertyId] }
            .map { [.select, .status, .multiSelect].contains($0.kind) && controller.view.groupSettings?.bucket?.string != "group" } ?? false
        grid.searchHighlight = controller.searchHighlight
        grid.totals = controller.totals
        grid.reloadData()
        needsLayout = true
        onHeightChange?()
    }

    /// Рамка шапки колонки свойства в координатах базы (окно новой колонки встаёт под ней).
    public func columnHeaderRect(_ propertyId: UUID) -> NSRect? {
        grid.headerRect(of: propertyId).map { convert($0, from: grid) }
    }

    /// Высота базы в странице: все показанные строки (у встроенной — по пределу загрузки), группы и полоса плашек.
    public func fittingHeight() -> CGFloat {
        let top = mode == .inline ? Self.titleHeight + (barSharesTitleRow ? 0 : ViewBarView.height) : ViewBarView.height
        return top + (showsChips ? ViewChipsBar.height : 0) + grid.fittingHeight + 1 + (controller.hasMoreRows ? Self.loadMoreHeight : 0) + 8
    }

    /// У встроенной базы с одним видом кнопки строки вида — в строке названия (Notion 7.39, `notion-inline-db-new.png`).
    var barSharesTitleRow: Bool { mode == .inline && !viewBar.showsTabs }

    /// Высота без вида (фабрика блока до показа): строк — по пределу загрузки.
    public static func height(rows: Int, hasMore: Bool, mode: Mode, barSharesTitleRow: Bool = true) -> CGFloat {
        // Шапка, строки, «+ Новая строка» и строка итогов (Q1: у Notion она есть всегда, под мышью — «Посчитать»).
        let grid = Metrics.DatabaseGrid.headerHeight + CGFloat(rows + 1) * Metrics.DatabaseGrid.rowHeight + GridLayout.totalsHeight + 2
        let top = mode == .inline ? titleHeight + (barSharesTitleRow ? 0 : ViewBarView.height) : ViewBarView.height
        return top + grid + (hasMore ? loadMoreHeight : 0) + 8
    }

    public override func layout() {
        super.layout()
        var y: CGFloat = 0
        if mode == .inline {
            titleField.frame = NSRect(x: 0, y: 8, width: bounds.width * (barSharesTitleRow ? 0.6 : 1), height: 28)
            if barSharesTitleRow {
                viewBar.frame = NSRect(x: 0, y: (Self.titleHeight - ViewBarView.height) / 2 + 2, width: bounds.width, height: ViewBarView.height)
            }
            y = Self.titleHeight
        }
        if !barSharesTitleRow {
            viewBar.frame = NSRect(x: 0, y: y, width: bounds.width, height: ViewBarView.height)
            y += ViewBarView.height
        }
        selectionBar.frame = viewBar.frame
        chipsBar.isHidden = !showsChips
        if showsChips {
            chipsBar.frame = NSRect(x: 0, y: y, width: bounds.width, height: ViewChipsBar.height)
            y += ViewChipsBar.height
        }
        let loadMore = loadMoreButton.isHidden ? 0 : Self.loadMoreHeight
        grid.frame = NSRect(x: 0, y: y, width: bounds.width, height: grid.fittingHeight)
        loadMoreButton.frame = NSRect(x: Metrics.DatabaseGrid.cellHorizontalPadding, y: grid.frame.maxY, width: 160, height: loadMore)
    }

    private func rowSelectionChanged(_ rows: Set<Int>) {
        selectionBar.count = rows.count
        selectionBar.isHidden = rows.isEmpty
        viewBar.isHidden = !rows.isEmpty
    }

    // MARK: Вид (US3)

    /// Значки строки вида и плашки: синие при фильтре и сортировке; полоса — после правки в этом окне.
    private func updateViewControls() {
        let view = controller.view
        let hasFilter = view.filterNode.map { !FilterEditing.root($0).children.isEmpty } ?? false
        let hasSorts = !view.sortSpecs.isEmpty
        var active: Set<ViewBarSlot> = []
        if hasFilter { active.insert(.filter) }
        if hasSorts { active.insert(.sort) }
        viewBar.activeSlots = active
        let current = (view.filter, view.sorts)
        if let last = lastFilterAndSorts, last.0 != current.0 || last.1 != current.1 { showsChips = hasFilter || hasSorts || showsChips }
        if !hasFilter, !hasSorts { showsChips = false }
        lastFilterAndSorts = current
        if showsChips { chipsBar.update(view: view, catalog: controller.catalog) }
        if viewBar.isSearching != (controller.search != nil) { viewBar.setSearching(controller.search != nil, text: controller.search ?? "") }
    }

    /// Показать полосу плашек (окно фильтра открывается от плашки).
    public func revealChips() {
        guard !showsChips else { return }
        showsChips = true
        chipsBar.update(view: controller.view, catalog: controller.catalog)
        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
    }

    /// Воронка: фильтр есть — показать плашки и окно первой; нет — список свойств «Фильтр по…».
    private func filterPressed(_ button: NSView) {
        let root = FilterEditing.root(controller.view.filterNode)
        guard !root.children.isEmpty else { return command(.addFilter, from: button) }
        revealChips()
        command(.filter([0]), from: chipsBar.subviews.first ?? button)
    }

    func command(_ command: ViewCommand, from anchor: NSView) {
        onViewCommand?(command, convert(anchor.bounds, from: anchor), self)
    }

    public func switchView(to viewId: UUID) {
        controller.switchView(to: viewId)
        showsChips = false
        lastFilterAndSorts = nil
        onViewSwitch?(viewId)
        refresh()
    }

    /// «+» в строке видов: новая таблица и сразу её настройки с выделенным именем.
    private func addView() {
        var created: UUID?
        controller.editView { operations, _ in created = try operations.addView(to: controller.databaseId) }
        guard let created else { return }
        switchView(to: created)
        command(.settings(selectName: true), from: viewBar)
    }

    /// Меню вкладки (`notion-view-tab-menu.png`): Переименовать, Изменить вид, Дублировать вид, Удалить вид (не при одном).
    private func showTabMenu(_ viewId: UUID, from tab: NSView) {
        if viewId != controller.viewId { switchView(to: viewId) }
        var entries: [ActionMenuEntry] = [
            .action(ActionMenuAction(title: "Переименовать", icon: "pencil", identifier: "view-tab-rename") { [weak self] _ in
                self?.command(.settings(selectName: true), from: tab)
            }),
            .action(ActionMenuAction(title: "Изменить вид", icon: "slider.horizontal.3", identifier: "view-tab-edit") { [weak self] _ in
                self?.command(.settings(selectName: false), from: tab)
            }),
            .action(ActionMenuAction(title: "Дублировать вид", icon: "plus.square.on.square", identifier: "view-tab-duplicate") { [weak self] _ in
                guard let self else { return }
                var copy: UUID?
                controller.editView { operations, id in copy = try operations.duplicateView(id) }
                guard let copy else { return }
                switchView(to: copy)
                command(.settings(selectName: true), from: viewBar)
            }),
        ]
        if viewBar.tabs.count > 1 {
            entries.append(.separator)
            entries.append(.action(ActionMenuAction(title: "Удалить вид", icon: "trash", identifier: "view-tab-delete") { [weak self] _ in
                guard let self else { return }
                controller.editView { operations, id in try operations.deleteView(id) }
                if let first = try? ViewQuery.firstViewId(of: controller.databaseId, in: controller.store) { switchView(to: first) }
            }))
        }
        let menu = ActionMenuView(entries: entries, width: Metrics.PageMenu.width)
        menu.onChoose = { [weak self] in self?.tabMenuCard.close() }
        guard let content = window?.contentView else { return }
        let rect = tab.convert(tab.bounds, to: nil)
        tabMenuCard.show(menu, size: menu.fittingSize, from: content.convert(NSPoint(x: rect.minX, y: rect.minY - 4), from: nil), in: content)
    }

    @objc private func loadMore() {
        controller.loadMore()
    }

    /// «Создать»: строка вверху вида, открывается способом вида (по умолчанию — сбоку), как в Notion.
    func createRowAtTop() {
        guard let row = controller.addRow(at: .top) else { return }
        controller.openRow(row)
    }

    // MARK: Название встроенной базы

    public func controlTextDidEndEditing(_ notification: Notification) {
        controller.setDatabaseTitle(titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        window?.makeFirstResponder(grid)
        return true
    }
}

/// Полоса над таблицей, когда строки отмечены флажками: «N выбрано │ Дублировать │ 🗑 │ •••».
@MainActor
final class RowSelectionBar: NSView {
    var count = 0 { didSet { label.stringValue = "\(count) выбрано" } }
    var onDuplicate: (() -> Void)?
    var onTrash: (() -> Void)?
    var onMore: ((NSView) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let duplicate = NSButton()
    private let trash = NSButton()
    private let more = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("database-selection-bar")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = Palette.checkboxChecked
        for (button, title, symbol, action) in [(duplicate, "Дублировать", nil, #selector(duplicatePressed)),
                                                (trash, "", "trash", #selector(trashPressed)),
                                                (more, "", "ellipsis", #selector(morePressed))] as [(NSButton, String, String?, Selector)] {
            button.isBordered = false
            button.title = title
            button.font = .systemFont(ofSize: 14)
            button.contentTintColor = Palette.textSecondary
            if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? symbol : title) }
            button.target = self
            button.action = action
            addSubview(button)
        }
        trash.setAccessibilityIdentifier("database-selection-trash")
        duplicate.setAccessibilityIdentifier("database-selection-duplicate")
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 4, y: midY - label.frame.height / 2)
        duplicate.sizeToFit()
        duplicate.frame.origin = NSPoint(x: label.frame.maxX + 16, y: midY - duplicate.frame.height / 2)
        trash.frame = NSRect(x: duplicate.frame.maxX + 12, y: midY - 12, width: 24, height: 24)
        more.frame = NSRect(x: trash.frame.maxX + 6, y: midY - 12, width: 24, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.pageBackground.setFill()
        bounds.fill()
    }

    @objc private func duplicatePressed() { onDuplicate?() }
    @objc private func trashPressed() { onTrash?() }
    @objc private func morePressed() { onMore?(more) }
}
