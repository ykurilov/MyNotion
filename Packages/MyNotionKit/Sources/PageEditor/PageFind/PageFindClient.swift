import AppKit
import NotesCore

/// ⌘F по всей странице (research R4): системная полоса поиска, но текст — вся страница по порядку показа:
/// поток страницы (и свёрнутое), колонки, ячейки таблиц. Совпадение показывается в своём редакторе:
/// в колонке, в поле правки ячейки; свёрнутое раскрывается.
@MainActor
final class PageFindClient: NSObject, @preconcurrency NSTextFinderClient {
    private weak var root: PageTextView?

    /// Кусок текста поиска: текст одного блока или ячейки.
    struct Segment {
        var range: NSRange
        var target: Target
    }

    enum Target: Equatable {
        /// Блок потока: страницы или колонки.
        case block(UUID)
        /// Ячейка таблицы по месту.
        case cell(table: UUID, row: Int, column: Int)
    }

    private var cache: (string: String, segments: [Segment])?
    /// Что выделено поиском в последний раз — если фокус ушёл туда, где поиск себя не узнает.
    private var lastSelection = NSRange(location: 0, length: 0)

    init(root: PageTextView) {
        self.root = root
    }

    /// Полоса поиска закрылась: курсор — на последнее найденное, в его редактор (как у Notion).
    func focusLastMatch() {
        guard hasFoundMatch else { return }
        hasFoundMatch = false
        selectedRanges = [NSValue(range: lastSelection)]
    }

    /// Поиск ставил выделение с тех пор, как полоса открылась.
    private var hasFoundMatch = false

        /// Текст страницы поменялся: собрать текст поиска заново при следующем обращении.
    func invalidate() {
        cache = nil
    }

    // MARK: Текст

    private var built: (string: String, segments: [Segment]) {
        if let cache { return cache }
        var string = ""
        var length = 0
        var segments: [Segment] = []
        func append(_ text: String, _ target: Target) {
            if !segments.isEmpty {
                string += "\n"
                length += 1
            }
            let units = (text as NSString).length
            segments.append(Segment(range: NSRange(location: length, length: units), target: target))
            string += text
            length += units
        }
        guard let document = root?.document.pageDocument else { return ("", []) }
        func walk(_ blocks: [Block]) {
            for block in blocks {
                switch block.kind {
                case .columnList:
                    for column in document.flow(block.id) { walk(document.flow(column.id)) }
                case .table:
                    guard let grid = document.tableGrid(block.id) else { continue }
                    for row in 0..<grid.rowCount {
                        for column in 0..<grid.columnCount {
                            append(grid.text(row: row, column: column).string, .cell(table: block.id, row: row, column: column))
                        }
                    }
                default:
                    if block.kind.rendersAsAttachment, block.text.string.isEmpty { continue }
                    append(block.text.string, .block(block.id))
                }
            }
        }
        walk(document.blocks)
        let result = (string, segments)
        cache = result
        return result
    }

    var string: String { built.string }

    func stringLength() -> Int { (built.string as NSString).length }

    private func segment(at location: Int) -> Segment? {
        let segments = built.segments
        var low = 0, high = segments.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = segments[middle].range
            if location < range.location { high = middle - 1 } else if location > NSMaxRange(range) { low = middle + 1 } else { return segments[middle] }
        }
        return nil
    }

    // MARK: Где показан текст

    /// Редактор, в котором стоит блок, и место блока в его тексте; блока нет на экране — `nil`.
    private func editor(showing blockId: UUID) -> (editor: PageTextView, start: Int)? {
        guard let root else { return nil }
        for editor in root.editorTree {
            guard let index = editor.document.index(ofBlock: blockId) else { continue }
            return (editor, editor.mapper.paragraphStart(ofBlockAt: index))
        }
        return nil
    }

    /// Показать место совпадения: раскрыть свёрнутое, развернуть вид колонок или таблицы.
    private func reveal(_ segment: Segment, focusing: Bool) {
        guard let root else { return }
        switch segment.target {
        case .block(let id):
            if focusing {
                root.revealBlock(id)
            } else if editor(showing: id) == nil {
                root.scrollToNestedBlock(id)
            }
        case .cell(let table, let row, let column):
            root.scrollToNestedBlock(table)
            if focusing { root.tableView(for: table)?.activate(TableCellPosition(row: row, column: column)) }
        }
    }

    // MARK: Выделение

    var isSelectable: Bool { true }
    var allowsMultipleSelection: Bool { false }
    var isEditable: Bool { false }

    var firstSelectedRange: NSRange { selectedRanges.first?.rangeValue ?? lastSelection }

    var selectedRanges: [NSValue] {
        get {
            guard let root, let focused = root.window?.firstResponder as? PageTextView,
                  root.editorTree.contains(where: { $0 === focused }) || focused is TableCellEditor else {
                return [NSValue(range: lastSelection)]
            }
            let selection = focused.selectedRange()
            if let cell = focused as? TableCellEditor, let table = cell.table, let active = table.activeCell,
               let found = built.segments.first(where: { $0.target == .cell(table: table.tableId, row: active.row, column: active.column) }) {
                return [NSValue(range: NSRange(location: found.range.location + min(selection.location, found.range.length), length: selection.length))]
            }
            guard let position = focused.mapper.blockPosition(at: selection.location),
                  let found = built.segments.first(where: { $0.target == .block(focused.document.blocks[position.index].id) }) else {
                return [NSValue(range: lastSelection)]
            }
            let location = found.range.location + min(position.offset, found.range.length)
            return [NSValue(range: NSRange(location: location, length: min(selection.length, NSMaxRange(found.range) - location)))]
        }
        set {
            guard let range = newValue.first?.rangeValue, let segment = segment(at: range.location) else { return }
            lastSelection = range
            hasFoundMatch = true
            reveal(segment, focusing: true)
            let local = NSRange(location: range.location - segment.range.location,
                                length: min(range.length, NSMaxRange(segment.range) - range.location))
            switch segment.target {
            case .block(let id):
                guard let (editor, start) = editor(showing: id) else { return }
                editor.window?.makeFirstResponder(editor)
                editor.setSelectedRange(NSRange(location: start + local.location, length: local.length))
            case .cell(let table, _, _):
                guard let cell = root?.tableView(for: table)?.editor else { return }
                cell.setSelectedRange(local)
            }
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        guard let segment = segment(at: range.location) else { return }
        reveal(segment, focusing: false)
        guard case .block(let id) = segment.target, let (editor, start) = editor(showing: id) else { return }
        editor.scrollRangeToVisible(NSRange(location: start + range.location - segment.range.location, length: range.length))
    }

    // MARK: Рамки совпадений

    /// Вид, где нарисован текст `index`, и отрезок текста поиска, который он показывает.
    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        guard let root else { return NSView() }
        guard let segment = segment(at: index) else {
            outRange.pointee = NSRange(location: 0, length: stringLength())
            return root
        }
        outRange.pointee = segment.range
        switch segment.target {
        case .block(let id):
            return editor(showing: id)?.editor ?? root
        case .cell(let table, let row, let column):
            guard let view = root.tableView(for: table) else { return root }
            if let editor = view.editor, view.activeCell == TableCellPosition(row: row, column: column) { return editor }
            return view
        }
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        guard let segment = segment(at: range.location) else { return nil }
        let local = NSRange(location: range.location - segment.range.location, length: min(range.length, NSMaxRange(segment.range) - range.location))
        switch segment.target {
        case .block(let id):
            guard let (editor, start) = editor(showing: id) else { return nil }
            return editor.textRects(for: NSRange(location: start + local.location, length: local.length)).map { NSValue(rect: $0) }
        case .cell(let table, let row, let column):
            guard let view = root?.tableView(for: table) else { return nil }
            let cell = TableCellPosition(row: row, column: column)
            if let editor = view.editor, view.activeCell == cell {
                return editor.textRects(for: local).map { NSValue(rect: $0) }
            }
            return [NSValue(rect: view.tableLayout.textRect(cell))]
        }
    }

    var visibleCharacterRanges: [NSValue] { [NSValue(range: NSRange(location: 0, length: stringLength()))] }
}

/// Поиск страницы: системный `NSTextFinder` с полосой над прокруткой страницы и клиентом на всю страницу.
@MainActor
final class PageFind: NSObject {
    let client: PageFindClient
    let finder = NSTextFinder()
    private weak var root: PageTextView?

    init(root: PageTextView) {
        self.root = root
        client = PageFindClient(root: root)
        super.init()
        finder.client = client
        finder.isIncrementalSearchingEnabled = true
        finder.incrementalSearchingShouldDimContentView = false
        for name in [PageDocument.didApplyLocalEdits, PageDocument.didApplyExternalChanges] {
            NotificationCenter.default.addObserver(self, selector: #selector(documentDidChange(_:)), name: name,
                                                   object: root.document.pageDocument)
        }
    }

    @objc private func documentDidChange(_ notification: Notification) {
        finder.noteClientStringWillChange()
        client.invalidate()
    }

    func perform(_ sender: Any?) {
        guard let tag = (sender as? NSValidatedUserInterfaceItem)?.tag, let action = NSTextFinder.Action(rawValue: tag) else { return }
        attachFindBar()
        finder.performAction(action)
    }

    /// Полоса — над прокруткой страницы; закрылась — курсор на найденное.
    private func attachFindBar() {
        guard finder.findBarContainer == nil, let scrollView = root?.enclosingScrollView else { return }
        finder.findBarContainer = scrollView
        (scrollView as? PageScrollView)?.onFindBarHidden = { [weak self] in
            DispatchQueue.main.async { self?.client.focusLastMatch() }
        }
    }

    func validate(_ tag: Int) -> Bool {
        guard let action = NSTextFinder.Action(rawValue: tag) else { return false }
        attachFindBar()
        return finder.validateAction(action)
    }
}

extension PageTextView {
    /// Полосы текста `range` в координатах этого редактора: по строке на отрезок.
    func textRects(for range: NSRange) -> [NSRect] {
        guard let textLayoutManager, let storage = textContentStorage,
              let start = storage.location(storage.documentRange.location, offsetBy: range.location),
              let end = storage.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        textLayoutManager.ensureLayout(for: textRange)
        var rects: [NSRect] = []
        let origin = textContainerOrigin
        textLayoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            rects.append(frame.offsetBy(dx: origin.x, dy: origin.y))
            return true
        }
        return rects
    }

    /// Клиент поиска страницы — у редактора страницы; колонки и ячейки ищут через него.
    var pageFindClient: PageFindClient? { pageEditor.pageFind.client }

    public override func performTextFinderAction(_ sender: Any?) {
        pageEditor.pageFind.perform(sender)
    }

    public override func performFindPanelAction(_ sender: Any?) {
        pageEditor.pageFind.perform(sender)
    }

    public override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(NSResponder.performTextFinderAction(_:)) || item.action == #selector(NSTextView.performFindPanelAction(_:)) {
            return pageEditor.pageFind.validate(item.tag)
        }
        return super.validateMenuItem(item)
    }
}

/// Прокрутка страницы: сообщает, что полоса поиска закрылась.
final class PageScrollView: NSScrollView {
    var onFindBarHidden: (() -> Void)?

    override var isFindBarVisible: Bool {
        didSet { if oldValue, !isFindBarVisible { onFindBarHidden?() } }
    }
}
