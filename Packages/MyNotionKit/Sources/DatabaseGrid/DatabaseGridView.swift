import AppKit
import Databases
import NotesCore
import VisualStyle

/// Сетка таблицы базы (research R4): документ во всю высоту таблицы в `NSScrollView`; рисуются только строки в видимой
/// полосе — слой документа делится AppKit на плитки, при прокрутке дорисовываются только открывшиеся; текст —
/// Core Text через кэш строк. Шапка колонок закреплена сверху (плавающий вид прокрутки).
/// Встроенная база (`scrollsVertically == false`) — та же сетка высотой по строкам, вертикальная прокрутка — у страницы.
/// Поведение (US1, contracts/database-ui.md, «Ячейки и клавиши»): выделение ячеек, правка на месте, клавиши и буфер,
/// шапка (меню колонки, протяжка края, перестановка, «+»), наведение строки («+», «⠿», флажок, «ОТКРЫТЬ»).
@MainActor
public final class DatabaseGridView: NSView {
    public let content: GridContent
    public let scrollView: NSScrollView
    let documentView: GridDocumentView
    let headerView: GridHeaderView
    public let scrollsVertically: Bool
    /// Таблица вида с правками; без неё (пробы) сетка только рисует.
    public weak var controller: DatabaseTableController?

    /// Выбранные ячейки; `nil` — ничего.
    public internal(set) var selection: CellSelection? { didSet { if selection != oldValue { documentView.selectionDidChange(from: oldValue) } } }
    /// Строки, отмеченные флажками (полоса «N выбрано»).
    public internal(set) var selectedRows: Set<Int> = [] {
        didSet {
            guard selectedRows != oldValue else { return }
            documentView.needsDisplay = true
            onRowSelectionChange?(selectedRows)
        }
    }
    /// Правка ячейки на месте; `nil` — не правится.
    var editor: CellEditorOverlay?
    let hoverControls = RowHoverControls()

    /// Щелчок по шапке колонки: меню колонки под ней (`rect` — в координатах сетки).
    public var onColumnMenu: ((DatabaseProperty, NSRect) -> Void)?
    /// «+» в шапке: новое свойство.
    public var onAddProperty: ((NSRect) -> Void)?
    /// «•••» в шапке: настройки вида.
    public var onViewSettings: ((NSRect) -> Void)?
    /// Правый щелчок по строке и щелчок по «⠿»: меню строки у точки (в координатах сетки).
    public var onRowMenu: ((Int, NSPoint) -> Void)?
    public var onRowSelectionChange: ((Set<Int>) -> Void)?
    /// Сколько строк «+ Новая строка» внизу (0 — нет, у проб).
    public var showsNewRowButton: Bool { controller != nil }

    public init(content: GridContent, scrollsVertically: Bool = true) {
        self.content = content
        self.scrollsVertically = scrollsVertically
        scrollView = scrollsVertically ? NSScrollView() : PassThroughScrollView()
        documentView = GridDocumentView(content: content)
        headerView = GridHeaderView(content: content)
        super.init(frame: .zero)
        documentView.grid = self
        headerView.grid = self
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = scrollsVertically
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = scrollsVertically ? .automatic : .none
        scrollView.documentView = documentView
        scrollView.addFloatingSubview(headerView, for: .vertical)
        addSubview(scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaChanged), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        content.onRowsLoaded = { [weak self] rows in self?.documentView.setNeedsDisplay(rows: rows) }
        hoverControls.grid = self
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Таблица базы")
        setAccessibilityIdentifier("database-grid")
        reloadData()
    }

    /// Сетка таблицы вида с правками.
    public convenience init(controller: DatabaseTableController, scrollsVertically: Bool) {
        self.init(content: controller.content, scrollsVertically: scrollsVertically)
        self.controller = controller
        reloadData()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public override var isFlipped: Bool { true }

    /// Высота всей таблицы (шапка, строки и «+ Новая строка») — для встроенной базы и страницы базы.
    public var fittingHeight: CGFloat { documentView.tableHeight + 1 }
    /// Ширина таблицы по колонкам (без «+» и «•••»).
    public var tableWidth: CGFloat { documentView.tableWidth }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        documentView.updateSize(minimumWidth: scrollView.contentSize.width)
        headerView.frame = NSRect(x: 0, y: 0, width: documentView.frame.width, height: Metrics.DatabaseGrid.headerHeight)
        editor?.frame = documentView.cellRect(row: editor?.position.row ?? 0, column: editor?.position.column ?? 0)
    }

    /// Новые строки или колонки: перерисовать всё.
    public func reloadData() {
        if let selection, selection.focus.row >= content.rowCount || selection.focus.column >= content.columns.count {
            self.selection = content.rowCount > 0 && !content.columns.isEmpty
                ? CellSelection(CellPosition(row: min(selection.focus.row, content.rowCount - 1), column: min(selection.focus.column, content.columns.count - 1)))
                : nil
        }
        selectedRows = selectedRows.filter { $0 < content.rowCount }
        documentView.updateSize(minimumWidth: scrollView.contentSize.width)
        headerView.frame = NSRect(x: 0, y: 0, width: documentView.frame.width, height: Metrics.DatabaseGrid.headerHeight)
        documentView.needsDisplay = true
        headerView.needsDisplay = true
        hoverControls.update()
        content.prefetch(around: visibleRows)
    }

    /// Перерисовать строку (уже перечитанную).
    public func redrawRow(_ index: Int) {
        documentView.setNeedsDisplay(rows: index..<index + 1)
    }

    /// Перечитать и перерисовать строку.
    public func reloadRow(at index: Int) {
        content.reloadRow(index)
        documentView.setNeedsDisplay(rows: index..<index + 1)
    }

    /// Строки в видимой части — с учётом прокрутки страницы у встроенной базы.
    public var visibleRows: Range<Int> { documentView.rows(in: documentView.visibleRect) }

    /// Рамка ячейки в координатах сетки (для проб и редактора ячейки).
    public func cellRect(row: Int, column: Int) -> NSRect {
        convert(documentView.cellRect(row: row, column: column), from: documentView)
    }

    /// Прокрутить так, чтобы строка `index` была у верха.
    public func scroll(toRow index: Int) {
        let y = CGFloat(index) * Metrics.DatabaseGrid.rowHeight
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Ячейка в видимой части: своя прокрутка и прокрутка страницы.
    func reveal(_ position: CellPosition) {
        documentView.scrollToVisible(documentView.cellRect(row: position.row, column: position.column).insetBy(dx: 0, dy: -4))
    }

    @objc private func visibleAreaChanged() {
        content.prefetch(around: visibleRows)
        hoverControls.update()
    }

    /// Прокрутка страницы (встроенная база): дочитать строки, которые она открыла.
    private var outerObserver: NSObjectProtocol?

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let outerObserver { NotificationCenter.default.removeObserver(outerObserver) }
        outerObserver = nil
        guard window != nil else {
            hoverControls.removeFromSuperview()
            return
        }
        if let outer = scrollView.enclosingScrollView {
            outer.contentView.postsBoundsChangedNotifications = true
            outerObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: outer.contentView,
                                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibleAreaChanged() }
            }
        }
        content.prefetch(around: visibleRows)
    }

    // MARK: Выделение и правка

    /// Выбрать ячейку (щелчок, переход клавишами) и сделать сетку получателем клавиш.
    public func select(_ position: CellPosition, extending: Bool = false) {
        guard position.row < content.rowCount, position.column < content.columns.count else { return }
        commitEditing(then: nil)
        if extending, var current = selection {
            current.extend(to: position)
            selection = current
        } else {
            selection = CellSelection(position)
        }
        selectedRows = []
        window?.makeFirstResponder(documentView)
        reveal(position)
    }

    var bounds2D: GridBounds { GridBounds(rows: content.rowCount, columns: content.columns.count) }

    /// Начать правку выбранной ячейки на месте; `replacingWith` — первая буква вместо содержимого.
    public func beginEditing(replacingWith text: String? = nil) {
        guard let controller, let position = selection?.focus, let column = content.columns[safe: position.column] else { return }
        switch CellKind.for(column.property.kind).editing {
        case .toggle:
            if text == nil { controller.toggleCheckbox(row: position.row, column: position.column) }
            return
        case .inPlace: break
        case .popup, .none: return
        }
        editor?.removeFromSuperview()
        let initial = text ?? controller.editingText(row: position.row, column: position.column)
        let overlay = CellEditorOverlay(position: position, text: initial, alignsRight: column.alignsRight,
                                        isTitle: column.property.kind == .title)
        overlay.frame = documentView.cellRect(row: position.row, column: position.column)
        overlay.onCommand = { [weak self] command in self?.commitEditing(then: command) }
        documentView.addSubview(overlay)
        editor = overlay
        reveal(position)
        overlay.focus(in: window)
        documentView.setNeedsDisplay(rows: position.row..<position.row + 1)
    }

    /// Закончить правку: значение записывается одним шагом, ячейка остаётся выбранной (Esc) или выбор шагает.
    func commitEditing(then move: CellMove?) {
        guard let overlay = editor else { return }
        editor = nil
        let position = overlay.position
        let text = overlay.text
        let changed = overlay.isEdited
        overlay.removeFromSuperview()
        window?.makeFirstResponder(documentView)
        if changed { controller?.commitText(text, row: position.row, column: position.column) }
        if let move {
            selection = CellSelection(position).moved(move, extending: false, in: bounds2D)
            if let focus = selection?.focus { reveal(focus) }
        } else {
            selection = CellSelection(position)
        }
        documentView.setNeedsDisplay(rows: position.row..<position.row + 1)
    }

    /// Правка шла, ячейку закрыли без команды (щелчок мимо, переход на другую страницу): значение записывается.
    func editorDidLoseFocus() { commitEditing(then: nil) }

    /// Команда клавиатуры на выбранной ячейке.
    func perform(_ command: CellCommand) -> Bool {
        switch command {
        case .move(let move, let extending):
            guard let selection else {
                if content.rowCount > 0, !content.columns.isEmpty { self.selection = CellSelection(CellPosition(row: 0, column: 0)) }
                return true
            }
            self.selection = selection.moved(move, extending: extending, in: bounds2D)
            if let focus = self.selection?.focus { reveal(focus) }
        case .beginEditing(let text):
            guard selection != nil else { return false }
            beginEditing(replacingWith: text)
        case .commit(let move): commitEditing(then: move)
        case .selectRow:
            guard let row = selection?.focus.row else { return false }
            selection = nil
            selectedRows = [row]
        case .selectAll: selectAll()
        case .copy: copySelection()
        case .cut:
            copySelection()
            eraseSelection()
        case .paste: pasteClipboard()
        case .erase:
            if !selectedRows.isEmpty {
                controller?.trashRows(selectedRows.sorted())
                selectedRows = []
            } else {
                eraseSelection()
            }
        case .duplicateRows:
            let rows = selectedRows.isEmpty ? selection.map { Array($0.rows) } ?? [] : selectedRows.sorted()
            guard !rows.isEmpty else { return false }
            controller?.duplicateRows(rows)
        case .openInNewTab:
            guard let row = selection?.focus.row ?? selectedRows.min() else { return false }
            controller?.openRow(row, inNewTab: true)
        case .none: return false
        }
        return true
    }

    func selectAll() {
        selection = CellSelection.all(in: bounds2D)
        selectedRows = []
    }

    func copySelection() {
        guard let controller, let selection else { return }
        CellClipboard.write(controller.copyValues(selection))
    }

    func eraseSelection() {
        guard let selection else { return }
        controller?.erase(selection)
    }

    func pasteClipboard() {
        guard let controller, let selection else { return }
        let values = CellClipboard.read()
        guard !values.isEmpty else { return }
        controller.paste(values, at: selection)
        // Выделение — вставленный блок (как в Notion и Numbers).
        if values.count > 1 || (values.first?.count ?? 0) > 1 {
            var pasted = CellSelection(selection.topLeft)
            pasted.extend(to: CellPosition(row: min(selection.topLeft.row + values.count - 1, content.rowCount - 1),
                                           column: min(selection.topLeft.column + (values.map(\.count).max() ?? 1) - 1, content.columns.count - 1)))
            self.selection = pasted
        }
    }

    /// Новая строка «+ Новая строка»: в конце, курсор в названии.
    func addRowAtBottom() {
        guard let controller, let row = controller.addRow(at: .bottom) else { return }
        select(CellPosition(row: row, column: 0))
        beginEditing()
    }

    /// «+» при наведении: строка под этой, курсор в названии.
    func addRow(after row: Int) {
        guard let controller, let rowId = content.rowId(at: row), let index = controller.addRow(at: .after(rowId)) else { return }
        select(CellPosition(row: index, column: 0))
        beginEditing()
    }

    /// Флажок строки при наведении.
    func toggleRowSelection(_ row: Int) {
        selection = nil
        if selectedRows.contains(row) { selectedRows.remove(row) } else { selectedRows.insert(row) }
    }

    /// Мышь над строкой (галерея и сценарии): «ОТКРЫТЬ» и ручки, как при наведении.
    public func showHover(row: Int) {
        documentView.hover(at: NSPoint(x: 40, y: documentView.rowRect(row).midY))
    }

    /// Протяжка от ячейки до ячейки (галерея и сценарии).
    public func selectRange(from start: CellPosition, to end: CellPosition) {
        select(start)
        select(end, extending: true)
    }

    /// Снять выделение (Esc в полосе «N выбрано», щелчок мимо таблицы).
    public func clearSelection() {
        commitEditing(then: nil)
        selection = nil
        selectedRows = []
    }
}

/// Прокрутка встроенной базы: колёсико по вертикали уходит странице.
final class PassThroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}
