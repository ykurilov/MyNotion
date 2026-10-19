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
        onResolveConflict = host.onResolveConflict
        openURL = host.openURL
        mentionDirectory = host.mentionDirectory
        pageLookup = host.pageLookup
        onRequestReminderPermission = host.onRequestReminderPermission
        if let store = host.blockViewState { blockViewState = store }
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

/// Виды блоков-контейнеров в тексте редактора (колонки, таблицы): живые виды и их высоты для раскладки знака-вложения.
@MainActor
final class EmbeddedBlockViews {
    /// Редактор сейчас ставит виды: смена их рамок не запускает раскладку заново.
    var isLayingOut = false
    /// Пока ставили виды, высота одного из них поменялась.
    var needsAnotherPass = false
    /// Поля правки ячеек таблиц страницы: живут, пока открыта страница, — их шаги ⌘Z остаются верны.
    var cellEditors: [CellKey: TableCellEditor] = [:]
    /// Высота вида по id блока при ширине, для которой она посчитана.
    private var heights: [UUID: (width: CGFloat, height: CGFloat)] = [:]
    private let views = NSMapTable<NSUUID, NSView>.strongToStrongObjects()

    func height(of blockId: UUID, width: CGFloat) -> CGFloat? {
        guard let entry = heights[blockId], abs(entry.width - width) < 0.5 else { return nil }
        return entry.height
    }

    func setHeight(_ height: CGFloat, of blockId: UUID, width: CGFloat) {
        heights[blockId] = (width, height)
    }

    func forgetHeight(of blockId: UUID) {
        heights[blockId] = nil
    }

    func register(_ view: NSView, for blockId: UUID) {
        views.setObject(view, forKey: blockId as NSUUID)
    }

    func view(for blockId: UUID) -> NSView? {
        views.object(forKey: blockId as NSUUID)
    }

    func blockId(of view: NSView) -> UUID? {
        guard let keys = views.keyEnumerator().allObjects as? [NSUUID] else { return nil }
        return keys.first { views.object(forKey: $0) === view } as UUID?
    }

    func unregister(_ blockId: UUID) {
        views.removeObject(forKey: blockId as NSUUID)
    }

    var liveViews: [NSView] {
        views.objectEnumerator()?.allObjects.compactMap { $0 as? NSView } ?? []
    }
}

extension PageTextView {
    /// Вид блока-контейнера сменил высоту: переложить только его абзац (research R2, проба T005).
    func embeddedViewHeightDidChange(_ blockId: UUID, height: CGFloat, width: CGFloat) {
        guard embeddedViews.height(of: blockId, width: width) != height else { return }
        embeddedViews.setHeight(height, of: blockId, width: width)
        relayoutParagraph(ofBlock: blockId)
        layoutEmbeddedViews()
    }

    /// Переложить абзац блока: высота его вида поменялась.
    func relayoutParagraph(ofBlock blockId: UUID) {
        guard let index = document.index(ofBlock: blockId), let textLayoutManager, let storage = textContentStorage else { return }
        let characters = mapper.characterRange(ofBlocksAt: index..<index + 1)
        guard let start = storage.location(storage.documentRange.location, offsetBy: characters.location),
              let end = storage.location(start, offsetBy: characters.length),
              let range = NSTextRange(location: start, end: end) else { return }
        textLayoutManager.invalidateLayout(for: range)
        textLayoutManager.textViewportLayoutController.layoutViewport()
        needsDisplay = true
        (self as? FlowTextView)?.onContentChange?()
    }

    /// Редакторы потоков внутри видов этого редактора — колонки по порядку слева направо.
    var embeddedFlowEditors: [FlowTextView] {
        embeddedViews.liveViews.flatMap { view -> [FlowTextView] in
            (view as? ColumnsView)?.editors ?? []
        }
    }

    /// Редакторы колонок блока колонок `listId`, слева направо; вида нет на экране — пусто.
    func flowEditors(inColumnList listId: UUID) -> [FlowTextView] {
        columnsView(for: listId)?.editors ?? []
    }

    func columnsView(for listId: UUID) -> ColumnsView? {
        embeddedViews.view(for: listId) as? ColumnsView
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
