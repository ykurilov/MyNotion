import AppKit
import NotesCore

/// Редактор потока без шапки (research R3): колонка или ячейка таблицы. Тот же `PageTextView`, что текст страницы, —
/// списки, переключатели, оформление, меню работают так же; правит свой поток документа и берёт отмену страницы,
/// поэтому ⌘Z идёт по правкам по порядку, где бы они ни были.
@MainActor
public class FlowTextView: PageTextView {
    /// Редактор, в тексте которого стоит вид этого редактора (колонок, таблицы).
    weak var host: PageTextView?

    init(flow: FlowDocument, host: PageTextView) {
        self.host = host
        super.init(flow: flow, initialFocus: .unchanged)
        fallbackUndoManager = host.undoManager
        drawsBackground = false
        isVerticallyResizable = false
        autoresizingMask = []
        adoptSettings(from: host)
        setAccessibilityIdentifier("flow-body")
    }

    override var showsPageHeader: Bool { false }

    override var column: (left: CGFloat, width: CGFloat) { (0, bounds.width) }

    /// Названия подстраниц, упоминания, свёрнутость и открытие ссылок — как у редактора страницы.
    func adoptSettings(from host: PageTextView) {
        linkedPages = host.linkedPages
        onOpenPage = host.onOpenPage
        onSubpageRequest = host.onSubpageRequest
        onResolveConflict = host.onResolveConflict
        pageLinkMenuEntries = host.pageLinkMenuEntries
        openURL = host.openURL
        mentionDirectory = host.mentionDirectory
        pageLookup = host.pageLookup
        onRequestReminderPermission = host.onRequestReminderPermission
        if let store = host.blockViewState { blockViewState = store }
        applyLayout(PageLayoutSettings(isSmallText: host.layoutSettings.isSmallText))
    }

    /// Высота текста потока без добавочной строки после последнего перевода строки.
    func contentHeight() -> CGFloat {
        guard let textLayoutManager else { return 0 }
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        var bottom: CGFloat = 0
        textLayoutManager.enumerateTextLayoutFragments(from: textLayoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let lines = fragment.textLineFragments
            var fragmentBottom = frame.maxY
            if let extra = lines.last, extra.characterRange.length == 0, lines.count > 1 {
                fragmentBottom = frame.minY + extra.typographicBounds.minY
            }
            if lines.contains(where: { $0.characterRange.length > 0 }) { bottom = max(bottom, fragmentBottom) }
            return true
        }
        return ceil(bottom)
    }

    /// Текст потока поменялся: виду вокруг (колонкам) — пересчитать высоту.
    var onContentChange: (@MainActor () -> Void)?

    public override func didChangeText() {
        super.didChangeText()
        onContentChange?()
    }
}

/// Высоты видов колонок и таблиц для раскладки их знака-вложения и поля правки ячеек страницы.
@MainActor
final class EmbeddedBlockViews {
    /// Поля правки ячеек таблиц страницы: живут, пока открыта страница, — их шаги ⌘Z остаются верны.
    var cellEditors: [CellKey: TableCellEditor] = [:]
    /// Высота вида по id блока при ширине, для которой она посчитана.
    private var heights: [UUID: (width: CGFloat, height: CGFloat)] = [:]

    func height(of blockId: UUID, width: CGFloat) -> CGFloat? {
        // Вид колонок шире знака на поля строки — та же ширина.
        guard let entry = heights[blockId], abs(entry.width - width) < 4.5 else { return nil }
        return entry.height
    }

    func setHeight(_ height: CGFloat, of blockId: UUID, width: CGFloat) {
        heights[blockId] = (width, height)
    }

    func forgetHeight(of blockId: UUID) {
        heights[blockId] = nil
    }
}

extension PageTextView {
    /// Вид блока-контейнера сменил высоту: переложить только его абзац (research R2, проба T005).
    func embeddedViewHeightDidChange(_ blockId: UUID, height: CGFloat, width: CGFloat) {
        guard embeddedViews.height(of: blockId, width: width) != height else { return }
        embeddedViews.setHeight(height, of: blockId, width: width)
        relayoutParagraph(ofBlock: blockId)
        blockViews.update()
        keepScrollAnchor()
    }

    /// Переложить абзац блока: высота его вида поменялась.
    func relayoutParagraph(ofBlock blockId: UUID) {
        guard let index = document.index(ofBlock: blockId), let textLayoutManager, let storage = textContentStorage else { return }
        let characters = mapper.characterRange(ofBlocksAt: index..<index + 1)
        guard let start = storage.location(storage.documentRange.location, offsetBy: characters.location),
              let end = storage.location(start, offsetBy: characters.length),
              let range = NSTextRange(location: start, end: end) else { return }
        textLayoutManager.invalidateLayout(for: range)
        layoutKeepingScrollAnchor { textLayoutManager.textViewportLayoutController.layoutViewport() }
        needsDisplay = true
        (self as? FlowTextView)?.onContentChange?()
    }

    /// Редакторы потоков внутри видов этого редактора — колонки по порядку слева направо.
    var embeddedFlowEditors: [FlowTextView] {
        embeddedContentViews.flatMap { view -> [FlowTextView] in
            (view as? ColumnsView)?.editors ?? []
        }
    }

    /// Виды блоков этого редактора, что сейчас на странице (`BlockViewHosting`): вид колонок, таблицы, кода…
    var embeddedContentViews: [NSView] {
        blockViews.views.values.compactMap(\.subviews.first)
    }

    /// Редакторы колонок блока колонок `listId`, слева направо; вида нет на экране — пусто.
    func flowEditors(inColumnList listId: UUID) -> [FlowTextView] {
        columnsView(for: listId)?.editors ?? []
    }

    func columnsView(for listId: UUID) -> ColumnsView? {
        blockViews.view(for: listId)?.subviews.first as? ColumnsView
    }

    /// Редактор страницы, в котором стоят все остальные.
    var pageEditor: PageTextView {
        var current: PageTextView = self
        while let host = (current as? FlowTextView)?.host { current = host }
        return current
    }

    /// Этот редактор и редакторы внутри его видов, вглубь.
    var editorTree: [PageTextView] {
        [self] + embeddedFlowEditors.flatMap(\.editorTree)
    }
}
