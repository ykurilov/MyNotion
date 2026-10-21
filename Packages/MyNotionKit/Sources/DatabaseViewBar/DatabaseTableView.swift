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

    public let controller: DatabaseTableController
    public let mode: Mode
    public let grid: DatabaseGridView
    public let viewBar = ViewBarView()
    let titleField = NSTextField()
    let loadMoreButton = NSButton()
    let selectionBar = RowSelectionBar()
    private let rowMenu = RowMenuPresenter()

    /// Высота сменилась (строки, «Загрузить ещё»): хозяин перекладывает строку блока.
    public var onHeightChange: (() -> Void)?
    /// Меню колонки, «+» и «•••» шапки — окна свойств (хозяин подключает `PropertyMenuPresenter`).
    public var onColumnMenu: ((DatabaseProperty, NSRect, NSView) -> Void)?
    public var onAddProperty: ((NSRect, NSView) -> Void)?
    public var onViewSettings: ((NSRect, NSView) -> Void)?
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
        grid = DatabaseGridView(controller: controller, scrollsVertically: mode == .page)
        super.init(frame: .zero)
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
        ]
        if mode == .inline { actions[.openFullPage] = { [weak self] _ in self?.onOpenAsPage?() } }
        viewBar.actions = actions
    }

    /// Строки или колонки сменились: перерисовать, у встроенной — пересчитать высоту.
    public func refresh() {
        viewBar.tabs = (try? controller.store.write { try $0.views(ofDatabase: controller.databaseId) })?.map { .init(id: $0.id, name: $0.name) } ?? []
        viewBar.activeTabId = controller.viewId
        // У встроенной базы с одним видом вкладки не видно (Notion 7.39).
        viewBar.showsTabs = !(mode == .inline && viewBar.tabs.count <= 1)
        if mode == .inline, titleField.currentEditor() == nil { titleField.stringValue = controller.title }
        loadMoreButton.isHidden = !controller.hasMoreRows
        grid.reloadData()
        needsLayout = true
        onHeightChange?()
    }

    /// Высота базы в странице при ширине `width`; на всю страницу — `available` (сетка листается сама).
    public func fittingHeight(available: CGFloat? = nil) -> CGFloat {
        if mode == .page, let available { return max(available, ViewBarView.height + 140) }
        return Self.height(rows: controller.content.rowCount, hasMore: controller.hasMoreRows, mode: mode)
    }

    /// Высота без вида (фабрика блока до показа): строк — по пределу загрузки.
    public static func height(rows: Int, hasMore: Bool, mode: Mode) -> CGFloat {
        let grid = Metrics.DatabaseGrid.headerHeight + CGFloat(rows + 1) * Metrics.DatabaseGrid.rowHeight + 2
        return (mode == .inline ? titleHeight : 0) + ViewBarView.height + grid + (hasMore ? loadMoreHeight : 0) + 8
    }

    public override func layout() {
        super.layout()
        var y: CGFloat = 0
        if mode == .inline {
            titleField.frame = NSRect(x: 0, y: 8, width: bounds.width, height: 28)
            y = Self.titleHeight
        }
        viewBar.frame = NSRect(x: 0, y: y, width: bounds.width, height: ViewBarView.height)
        selectionBar.frame = viewBar.frame
        y += ViewBarView.height
        let loadMore = loadMoreButton.isHidden ? 0 : Self.loadMoreHeight
        let gridHeight = mode == .page ? bounds.height - y : grid.fittingHeight
        grid.frame = NSRect(x: 0, y: y, width: bounds.width, height: max(0, gridHeight))
        loadMoreButton.frame = NSRect(x: Metrics.DatabaseGrid.cellHorizontalPadding, y: grid.frame.maxY, width: 160, height: loadMore)
    }

    private func rowSelectionChanged(_ rows: Set<Int>) {
        selectionBar.count = rows.count
        selectionBar.isHidden = rows.isEmpty
        viewBar.isHidden = !rows.isEmpty
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
