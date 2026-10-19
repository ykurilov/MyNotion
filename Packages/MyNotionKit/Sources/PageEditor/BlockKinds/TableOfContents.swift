import AppKit
import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    /// Оглавление (US4, FR-106): строки заголовков страницы с отступами; щелчок — к заголовку.
    static let tableOfContents = BlockKindDescriptor(
        kind: .tableOfContents,
        menuItem: PopupMenuItem(title: "Оглавление", icon: .symbol("list.bullet.indent"),
                                keywords: ["toc", "table of contents", "оглавление", "содержание"], action: .setKind(.tableOfContents)),
        gallerySamples: [
            BlockGallerySample(id: "toc-headings", summary: "Оглавление над заголовками трёх уровней",
                               blocks: [
                                   .init(.tableOfContents),
                                   .init(.heading1, "Введение"),
                                   .init(.paragraph, "Текст введения"),
                                   .init(.heading2, "Установка"),
                                   .init(.heading3, "На Mac"),
                                   .init(.heading3, "На втором Mac"),
                                   .init(.heading2, "Синхронизация"),
                                   .init(.heading1, "Итог"),
                               ], narrowToo: true),
            BlockGallerySample(id: "toc-empty", summary: "Оглавление на странице без заголовков — подсказка",
                               blocks: [.init(.tableOfContents), .init(.paragraph, "Страница без заголовков")]),
        ],
        // Богатая страница (quickstart.md): одно оглавление.
        richPageBlocks: [RichBlockSpec(.tableOfContents)]
    )
}

/// Строки оглавления из документа (research R7): заголовки потока страницы и колонок по порядку, без обхода текста.
@MainActor
enum TableOfContents {
    struct Entry: Equatable {
        var id: UUID
        /// 0 — заголовок 1, 1 — заголовок 2, 2 — заголовок 3.
        var level: Int
        var title: String
    }

    static let rowHeight: CGFloat = 28
    static let indentStep: CGFloat = 24
    static let verticalPadding: CGFloat = 4
    static let hint = "Добавьте заголовки, чтобы появилось оглавление"

    static func entries(in document: PageDocument) -> [Entry] {
        var result: [Entry] = []
        func visit(_ blocks: [Block]) {
            for block in blocks {
                switch block.kind {
                case .heading1, .heading2, .heading3:
                    let level = block.kind == .heading1 ? 0 : block.kind == .heading2 ? 1 : 2
                    result.append(Entry(id: block.id, level: level, title: block.text.string.replacingOccurrences(of: "\n", with: " ")))
                case .columnList, .column:
                    visit(document.flow(block.id))
                default:
                    break
                }
            }
        }
        visit(document.blocks)
        return result
    }

    /// Документы открытых страниц: по ним фабрика узнаёт высоту оглавления, у которой нет своего текста.
    private final class WeakDocument {
        weak var document: PageDocument?
        init(_ document: PageDocument) { self.document = document }
    }

    private static var documents: [UUID: WeakDocument] = [:]
    private static var cachedEntries: [UUID: [Entry]] = [:]

    static func track(_ document: PageDocument) {
        documents[document.page.id] = WeakDocument(document)
        cachedEntries[document.page.id] = nil
    }

    /// Строки оглавления страницы `pageId` (последние известные).
    static func entries(forPage pageId: UUID) -> [Entry] {
        if let cached = cachedEntries[pageId] { return cached }
        guard let document = documents[pageId]?.document else { return [] }
        let entries = entries(in: document)
        cachedEntries[pageId] = entries
        return entries
    }

    /// Документ поправили: строки заново; `true` — изменились.
    static func refresh(_ document: PageDocument) -> Bool {
        let entries = entries(in: document)
        defer { cachedEntries[document.page.id] = entries }
        return cachedEntries[document.page.id] != entries
    }

    static func height(rows: Int) -> CGFloat {
        CGFloat(max(1, rows)) * rowHeight + 2 * verticalPadding
    }
}

/// Следит за документом страницы: правка заголовка — новые строки во всех оглавлениях страницы и их высота.
@MainActor
final class TableOfContentsTracker {
    weak var textView: PageTextView?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(textView: PageTextView) {
        self.textView = textView
        let document = textView.document
        TableOfContents.track(document)
        for name in [PageDocument.didApplyLocalEdits, PageDocument.didApplyExternalChanges] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: document, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.documentDidChange() }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func documentDidChange() {
        guard let textView else { return }
        let document = textView.document
        guard document.blocks.contains(where: { $0.kind == .tableOfContents }) || !(TableOfContents.entries(forPage: document.page.id).isEmpty) else {
            return
        }
        let rowsBefore = TableOfContents.entries(forPage: document.page.id).count
        guard TableOfContents.refresh(document) else { return }
        let rowsAfter = TableOfContents.entries(forPage: document.page.id).count
        for block in document.blocks where block.kind == .tableOfContents {
            textView.tableOfContentsViews.view(for: block.id)?.reload()
            if rowsBefore != rowsAfter { textView.invalidateAttachmentLayout(ofBlock: block.id) }
        }
    }
}

/// Виды оглавлений страницы по id блока.
@MainActor
final class TableOfContentsViews {
    private final class WeakView {
        weak var view: TableOfContentsView?
        init(_ view: TableOfContentsView) { self.view = view }
    }

    private var views: [UUID: WeakView] = [:]

    func view(for id: UUID) -> TableOfContentsView? { views[id]?.view }

    func register(_ view: TableOfContentsView) {
        views = views.filter { $0.value.view != nil }
        views[view.blockId] = WeakView(view)
    }
}

/// Фабрика вида оглавления.
@MainActor
final class TableOfContentsViewFactory: BlockViewFactory {
    func makeView(for block: Block, context: BlockViewContext) -> NSView? {
        let view = TableOfContentsView(block: block, page: context.textView)
        context.textView?.tableOfContentsViews.register(view)
        return view
    }

    func height(for block: Block, width: CGFloat) -> CGFloat? {
        TableOfContents.height(rows: TableOfContents.entries(forPage: block.pageId).count)
    }
}

/// Строки заголовков: textSecondary 14, отступ 24 на уровень, подчёркивание под мышью; нет заголовков — серая подсказка.
@MainActor
final class TableOfContentsView: NSView, BlockFieldsView {
    let blockId: UUID
    let pageId: UUID
    weak var page: PageTextView?
    private(set) var entries: [TableOfContents.Entry] = []
    private var hoveredRow: Int? {
        didSet { if hoveredRow != oldValue { needsDisplay = true } }
    }
    private var hoverArea: NSTrackingArea?

    static let font = NSFont.systemFont(ofSize: 14)

    var rowTitles: [String] { entries.map(\.title) }
    var rowIndents: [CGFloat] { entries.map { CGFloat($0.level) * TableOfContents.indentStep } }
    var hint: String? { entries.isEmpty ? TableOfContents.hint : nil }

    init(block: Block, page: PageTextView?) {
        blockId = block.id
        pageId = block.pageId
        self.page = page
        super.init(frame: NSRect(x: 0, y: 0, width: 720, height: TableOfContents.height(rows: 1)))
        setAccessibilityIdentifier("table-of-contents")
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    func update(_ block: Block) { reload() }

    func reload() {
        entries = TableOfContents.entries(forPage: pageId)
        setAccessibilityValue(entries.map(\.title).joined(separator: "\n"))
        needsDisplay = true
    }

    private func rowRect(_ index: Int) -> NSRect {
        NSRect(x: 0, y: TableOfContents.verticalPadding + CGFloat(index) * TableOfContents.rowHeight, width: bounds.width,
               height: TableOfContents.rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !entries.isEmpty else {
            let text = NSAttributedString(string: TableOfContents.hint, attributes: [.font: Self.font, .foregroundColor: Palette.textSecondary])
            text.draw(at: NSPoint(x: 2, y: rowRect(0).midY - text.size().height / 2))
            return
        }
        for (index, entry) in entries.enumerated() {
            let rect = rowRect(index)
            guard rect.intersects(dirtyRect) else { continue }
            var attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: Palette.textSecondary]
            if hoveredRow == index {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            let text = NSAttributedString(string: entry.title.isEmpty ? "Заголовок" : entry.title, attributes: attributes)
            text.draw(at: NSPoint(x: 2 + CGFloat(entry.level) * TableOfContents.indentStep, y: rect.midY - text.size().height / 2))
        }
    }

    private func row(at point: NSPoint) -> Int? {
        let index = Int((point.y - TableOfContents.verticalPadding) / TableOfContents.rowHeight)
        return index >= 0 && index < entries.count ? index : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) { hoveredRow = row(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hoveredRow = nil }

    override func resetCursorRects() {
        for index in entries.indices { addCursorRect(rowRect(index), cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = row(at: convert(event.locationInWindow, from: nil)) else {
            page?.attachmentViewClicked(blockId: blockId)
            return
        }
        activateRow(index)
    }

    /// Перейти к заголовку строки `index`.
    func activateRow(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        page?.goToHeading(entries[index].id)
    }
}

extension PageTextView {
    /// Щелчок по строке оглавления: свёрнутые предки раскрываются, курсор — в начало заголовка, заголовок — у верхнего
    /// края окна с запасом 80 (contracts/blocks-and-keys.md, «Оглавление»).
    func goToHeading(_ id: UUID) {
        revealBlock(id)
        guard let index = document.index(ofBlock: id), let scroll = enclosingScrollView else { return }
        let rect = rectOfCharacters(NSRange(location: mapper.paragraphStart(ofBlockAt: index), length: 0))
        guard !rect.isEmpty || rect.origin != .zero else { return }
        let clip = scroll.contentView
        let maxY = max(0, frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, rect.minY - 80), maxY)))
        scroll.reflectScrolledClipView(clip)
    }
}

extension PageTextView {
    /// «/» → «Оглавление»: пустой блок сам становится оглавлением, у блока с текстом оглавление встаёт ниже;
    /// под оглавлением — новый абзац с курсором, как у разделителя. Одно действие для ⌘Z.
    func insertTableOfContents(at index: Int) {
        commitEdits()
        let block = document.blocks[index]
        let toc = BlockDraft(id: block.text.string.isEmpty ? block.id : nil, kind: .tableOfContents, indent: block.indent)
        let paragraph = BlockDraft(id: nil, kind: .paragraph, indent: block.indent)
        let drafts = block.text.string.isEmpty ? [toc, paragraph] : [BlockDraft(block), toc, paragraph]
        changeBlocks(index..<index + 1, to: drafts, actionName: "Оглавление")
        setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: index + drafts.count - 1), length: 0))
    }
}
