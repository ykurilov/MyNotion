import AppKit
import NotesCore
import VisualStyle

/// Вид блока колонок (contracts/blocks-and-keys.md, «Колонки»; research R3): 2–5 редакторов `FlowTextView` рядом,
/// каждый — поток своей колонки. Ширины — доли колонок; границу тянут мышью. Высота — по самой высокой колонке.
@MainActor
final class ColumnsView: NSView {
    let listId: UUID
    let document: PageDocument
    private weak var host: PageTextView?
    private(set) var editors: [FlowTextView] = []
    private var dividers: [ColumnDividerView] = []
    /// Доли ширины, пока границу тянут: запись — одной правкой при отпускании.
    private var draftRatios: [Double]?

    init(document: PageDocument, listId: UUID, host: PageTextView) {
        self.document = document
        self.listId = listId
        self.host = host
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("columns")
        reloadColumns()
        for name in [PageDocument.didApplyLocalEdits, PageDocument.didApplyExternalChanges] {
            NotificationCenter.default.addObserver(self, selector: #selector(documentDidChange(_:)), name: name, object: document)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var columns: [Block] { document.flow(listId).filter { $0.kind == .column } }

    /// Редакторы под колонки документа: новые колонки получают редактор, ушедшие — теряют.
    private func reloadColumns() {
        guard let host else { return }
        let columns = columns
        var byColumn = Dictionary(uniqueKeysWithValues: editors.compactMap { editor in editor.document.containerId.map { ($0, editor) } })
        editors = columns.map { column in
            if let editor = byColumn.removeValue(forKey: column.id) { return editor }
            let editor = FlowTextView(flow: FlowDocument(document, source: .container(column.id)), host: host)
            editor.onContentChange = { [weak self] in self?.needsLayout = true }
            addSubview(editor)
            return editor
        }
        byColumn.values.forEach { $0.removeFromSuperview() }
        while dividers.count < max(0, editors.count - 1) {
            let divider = ColumnDividerView()
            let index = dividers.count
            divider.onDrag = { [weak self] x in self?.dragDivider(index, toX: x) }
            divider.onRelease = { [weak self] in self?.commitDraftRatios() }
            addSubview(divider)
            dividers.append(divider)
        }
        while dividers.count > max(0, editors.count - 1) { dividers.removeLast().removeFromSuperview() }
        layoutEditors()
    }

    @objc private func documentDidChange(_ notification: Notification) {
        guard let change = notification.userInfo?[PageDocument.externalChangeKey] as? PageDocument.ExternalChange else { return }
        let columnIds = Set(editors.compactMap(\.document.containerId))
        if change.changedFlowIds.contains(listId) || change.removedBlockIds.contains(where: columnIds.contains) {
            draftRatios = nil
            reloadColumns()
        } else if !change.changedFlowIds.isDisjoint(with: columnIds) {
            needsLayout = true
        }
    }

    // MARK: Раскладка

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { layoutEditors() }
    }

    override func layout() {
        super.layout()
        layoutEditors()
    }

    /// Левый край и ширина каждой колонки при ширине вида `width`.
    static func columnFrames(ratios: [Double], width: CGFloat) -> [(x: CGFloat, width: CGFloat)] {
        let gap = Metrics.Columns.gap
        let usable = max(0, width - gap * CGFloat(max(0, ratios.count - 1)))
        var x: CGFloat = 0
        return ratios.map { ratio in
            let columnWidth = (usable * ratio).rounded()
            defer { x += columnWidth + gap }
            return (x, columnWidth)
        }
    }

    func layoutEditors() {
        let ratios = draftRatios ?? ColumnLayout.ratios(of: columns)
        guard ratios.count == editors.count else { return }
        // Вид стоит с места текста страницы, а редакторы колонок сами отступают поле строки: сдвинуть их на него,
        // и текст колонок встаёт вровень с текстом страницы.
        let padding = editors.first?.textContainer?.lineFragmentPadding ?? 0
        let frames = Self.columnFrames(ratios: ratios, width: bounds.width).map { (x: $0.x - padding, width: $0.width + padding) }
        var height: CGFloat = 0
        for (editor, frame) in zip(editors, frames) {
            if editor.frame.width != frame.width || editor.frame.minX != frame.x {
                editor.frame = NSRect(x: frame.x, y: 0, width: frame.width, height: max(editor.frame.height, 1))
            }
            let content = editor.contentHeight()
            if editor.frame.height != content { editor.setFrameSize(NSSize(width: frame.width, height: content)) }
            height = max(height, content)
        }
        for (index, divider) in dividers.enumerated() where index + 1 < frames.count {
            let left = frames[index].x + frames[index].width
            divider.frame = NSRect(x: left, y: 0, width: frames[index + 1].x - left, height: max(height, bounds.height))
        }
        host?.embeddedViewHeightDidChange(listId, height: height, width: bounds.width)
    }

    /// Высота колонок при ширине `width`, пока вида нет: потоки раскладываются вне экрана.
    static func estimatedHeight(of listId: UUID, in document: PageDocument, width: CGFloat) -> CGFloat {
        let columns = document.flow(listId).filter { $0.kind == .column }
        let frames = columnFrames(ratios: ColumnLayout.ratios(of: columns), width: width)
        return zip(columns, frames).map { column, frame in
            let storage = NSTextContentStorage()
            let layoutManager = NSTextLayoutManager()
            storage.addTextLayoutManager(layoutManager)
            let container = NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = Metrics.Page.blockHorizontalPadding
            layoutManager.textContainer = container
            storage.attributedString = PageTextStorageMapper.attributedText(for: document.flow(column.id))
            layoutManager.ensureLayout(for: layoutManager.documentRange)
            return layoutManager.usageBoundsForTextContainer.height - Typography.line(for: .paragraph).lineHeight
        }.max().map { max($0, Typography.line(for: .paragraph).lineHeight) } ?? 0
    }

    // MARK: Граница колонок

    /// Протянуть границу `index` (между колонками `index` и `index + 1`): доля левой из двух — `fraction`.
    /// Запись — одной правкой при отпускании; доли урезаются до 10–90 %.
    func dragDivider(_ index: Int, toFraction fraction: Double) {
        var ratios = draftRatios ?? ColumnLayout.ratios(of: columns)
        guard index + 1 < ratios.count else { return }
        let pair = ratios[index] + ratios[index + 1]
        ratios[index] = pair * min(max(fraction, 0), 1)
        ratios[index + 1] = pair - ratios[index]
        draftRatios = ratios
        commitDraftRatios()
    }

    private func dragDivider(_ index: Int, toX x: CGFloat) {
        var ratios = draftRatios ?? ColumnLayout.ratios(of: columns)
        let frames = Self.columnFrames(ratios: ratios, width: bounds.width)
        guard index + 1 < frames.count else { return }
        let start = frames[index].x
        let end = frames[index + 1].x + frames[index + 1].width - Metrics.Columns.gap
        let fraction = min(max((x - Metrics.Columns.gap / 2 - start) / max(1, end - start), 0), 1)
        let pair = ratios[index] + ratios[index + 1]
        let lowest = ColumnLayout.ratioRange.lowerBound
        ratios[index] = min(max(pair * fraction, lowest), pair - lowest)
        ratios[index + 1] = pair - ratios[index]
        draftRatios = ratios
        layoutEditors()
    }

    private func commitDraftRatios() {
        guard let ratios = draftRatios, let host else { return }
        draftRatios = nil
        if let changes = document.changesSettingColumnRatios(ratios, ofColumnList: listId) {
            host.applyStructuralChanges(changes, actionName: "Ширина колонок")
        }
        layoutEditors()
    }

    // MARK: Мышь

    /// Щелчок мимо текста колонки (под короткой колонкой) — курсор в конец этой колонки.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let editor = editors.min(by: { abs($0.frame.midX - point.x) < abs($1.frame.midX - point.x) }) else { return }
        editor.focus(atEnd: true)
    }
}

/// Граница между колонками: при наведении — полоса, её тянут.
@MainActor
final class ColumnDividerView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onRelease: (() -> Void)?
    private var isHovered = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { onRelease?() }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        Palette.border.setFill()
        let width = Metrics.Columns.dividerWidth
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - width / 2, y: 0, width: width, height: bounds.height),
                     xRadius: width / 2, yRadius: width / 2).fill()
    }
}

/// Фабрика вида колонок: вид — `ColumnsView`, высота — по колонкам.
@MainActor
final class ColumnsViewFactory: BlockViewFactory {
    func makeView(for block: Block, context: BlockViewContext) -> NSView? {
        guard let textView = context.textView else { return nil }
        let view = ColumnsView(document: textView.document.pageDocument, listId: block.id, host: textView)
        view.frame.size.width = context.width
        return view
    }

    func height(for block: Block, width: CGFloat) -> CGFloat? { nil }

    func height(for block: Block, width: CGFloat, context: BlockViewContext) -> CGFloat? {
        guard let textView = context.textView else { return nil }
        if let known = textView.embeddedViews.height(of: block.id, width: width) { return known }
        let estimated = ColumnsView.estimatedHeight(of: block.id, in: textView.document.pageDocument, width: width)
        textView.embeddedViews.setHeight(estimated, of: block.id, width: width)
        return estimated
    }
}

extension PageTextView {
    /// Фокус в этот редактор: курсор в начало или в конец текста.
    public func focus(atEnd: Bool) {
        window?.makeFirstResponder(self)
        let length = max(0, (textStorage?.length ?? 1) - 1)
        setSelectedRange(NSRange(location: atEnd ? length : 0, length: 0))
    }
}
