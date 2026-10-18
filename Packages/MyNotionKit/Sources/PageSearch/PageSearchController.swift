import AppKit
import NotesCore
import VisualStyle

/// Поиск страниц в боковой панели (FR-018): поле вверху панели и выдача под ним во всплывающей карточке.
/// Ввод сразу показывает выдачу, ↑↓ выбирают строку, Enter открывает страницу, Esc закрывает выдачу и очищает поле.
/// Выдача закрывается, когда поле теряет фокус и когда приложение уходит в фон; без видимого окна на экран не выходит.
@MainActor
public final class PageSearchController: NSObject, NSTextFieldDelegate {
    private let search: PageSearch
    private let currentTree: () -> PageTreeSnapshot
    private let openPage: (UUID) -> Void
    weak var fieldView: SearchFieldView?
    private var panel: SearchResultsPanel?
    private var deactivationObserver: NSObjectProtocol?

    /// Выдача по тексту в поле; пусто — поле пустое или ничего не нашлось.
    public private(set) var results: [PageSearchResult] = []
    /// Подсвеченная строка выдачи.
    public private(set) var selectedIndex = 0

    /// `tree` — дерево на момент ввода: из него выдача берёт названия и отсекает корзину.
    public init(store: NotesStore, tree: @escaping () -> PageTreeSnapshot, open: @escaping (UUID) -> Void) {
        search = PageSearch(store: store)
        currentTree = tree
        openPage = open
    }

    public var query: String { fieldView?.textField.stringValue ?? "" }

    /// Выдача на экране.
    public var isShowingResults: Bool { panel?.isVisible == true }

    /// Место карточки выдачи без тени, в координатах экрана; `nil` — выдача закрыта.
    public var resultsCardFrame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame.insetBy(dx: SearchResultsPanel.shadowMargin, dy: SearchResultsPanel.shadowMargin)
    }

    /// ⇧⌘F: курсор в поле поиска, набранное выделено.
    public func focusField() {
        guard let field = fieldView?.textField, let window = field.window else { return }
        window.makeFirstResponder(field)
    }

    /// Поставить курсор в поле и набрать `text`, как с клавиатуры (галерея состояний).
    public func type(_ text: String) {
        focusField()
        fieldView?.textField.stringValue = text
        fieldView?.textField.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        queryDidChange()
    }

    // MARK: Ввод

    public func controlTextDidChange(_ obj: Notification) {
        queryDidChange()
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        closeResults()
        fieldView?.textField.stringValue = ""
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            openSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default:
            return false
        }
        return true
    }

    private func queryDidChange() {
        let query = self.query
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            closeResults()
            return
        }
        results = (try? search.results(for: query, in: currentTree())) ?? []
        selectedIndex = 0
        showResults()
    }

    private func moveSelection(by step: Int) {
        guard !results.isEmpty else { return }
        select(min(max(0, selectedIndex + step), results.count - 1))
    }

    private func select(_ index: Int) {
        selectedIndex = index
        panel?.resultsView.selectedIndex = index
        panel?.resultsView.scrollSelectionToVisible()
    }

    private func openSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        open(results[selectedIndex].pageId)
    }

    private func open(_ pageId: UUID) {
        dismiss()
        openPage(pageId)
    }

    /// Закрыть выдачу, очистить поле и уйти из него (Esc).
    public func dismiss() {
        closeResults()
        guard let field = fieldView?.textField else { return }
        field.stringValue = ""
        results = []
        if let window = field.window, field.currentEditor() != nil { window.makeFirstResponder(nil) }
    }

    // MARK: Выдача

    private func showResults() {
        guard let fieldView, let window = fieldView.window else { return }
        let panel = self.panel ?? makePanel()
        panel.resultsView.show(results, selectedIndex: selectedIndex)
        let fieldRect = window.convertToScreen(fieldView.convert(fieldView.bounds, to: nil))
        let card = SearchResultsPlacement.card(height: panel.resultsView.preferredCardHeight, below: fieldRect,
                                               within: window.frame)
        panel.setFrame(card.insetBy(dx: -SearchResultsPanel.shadowMargin, dy: -SearchResultsPanel.shadowMargin), display: true)
        guard PopupWindows.show(panel, over: window) else { return }
        if deactivationObserver == nil {
            deactivationObserver = PopupWindows.onAppDeactivation { [weak self] in self?.dismiss() }
        }
    }

    private func makePanel() -> SearchResultsPanel {
        let panel = SearchResultsPanel()
        panel.resultsView.onHover = { [weak self] index in self?.select(index) }
        panel.resultsView.onClick = { [weak self] index in
            guard let self, results.indices.contains(index) else { return }
            open(results[index].pageId)
        }
        self.panel = panel
        return panel
    }

    private func closeResults() {
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        deactivationObserver = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

/// Место карточки выдачи: левым краем по полю, на `anchorSpacing` ниже него; по ширине и высоте — в окне `within`.
/// Координаты экрана.
enum SearchResultsPlacement {
    static func card(height: CGFloat, below field: NSRect, within window: NSRect) -> NSRect {
        let metrics = Metrics.SearchResults.self
        let margin = Metrics.TrashPanel.windowMargin
        let width = max(field.width, min(metrics.width, window.maxX - margin - field.minX))
        let top = field.minY - metrics.anchorSpacing
        let cardHeight = max(0, min(height, metrics.maxHeight, top - window.minY - margin))
        return NSRect(x: field.minX, y: top - cardHeight, width: width, height: cardHeight)
    }
}
