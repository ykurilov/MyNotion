import AppKit
import DatabaseGrid
import Databases
import NotesCore
import VisualStyle

/// Окна строки вида (US3, contracts/database-ui.md, «Настройки вида»; contracts/property-types.md): фильтр простой и
/// расширенный, сортировка, видимость свойств, группировка, раскладка, панель «Настройки вида». Все правки — операциями
/// (`controller.editView`, шаг ⌘Z каждая); открытые окна перечитывают себя по `DatabaseOperations.didChange`.
/// Esc и щелчок мимо закрывают.
@MainActor
public final class ViewPanels {
    let controller: DatabaseTableController
    private let card = PopupCard()
    /// Выпадающие списки по уровням: 1 — из окна или панели, 2 — из окна значения расширенного фильтра.
    private var menuCards: [Int: PopupCard] = [:]
    private var page: PanelPage?
    private var menuPages: [Int: PanelPage] = [:]
    private var anchor: (rect: NSRect, view: NSView)?
    private var swapping = false
    private var settingsPanel: ViewSettingsPanel?
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    /// «Свойства ›» в «Настройках вида»: окно «Свойства» базы под строкой (рамка и вид строки).
    public var onShowProperties: ((NSRect, NSView) -> Void)?

    public init(controller: DatabaseTableController) {
        self.controller = controller
        card.onClose = { [weak self] in
            guard let self, !self.swapping else { return }
            self.page?.flush()
            self.page = nil
            self.closeMenus(from: 1)
        }
        observer = NotificationCenter.default.addObserver(forName: DatabaseOperations.didChange, object: nil, queue: .main) { [weak self] _ in
            // Таблица перечитывает вид тем же уведомлением: окна — после неё.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.databaseDidChange() } }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Вход

    /// «+ Фильтр» и воронка без фильтров: список свойств «Фильтр по…» (по алфавиту, поиск, внизу «+ Расширенный фильтр»);
    /// выбор — плашка с условием по умолчанию и сразу её окно.
    public func showAddFilter(below rect: NSRect, in view: NSView) {
        let controller = controller
        let choices = PropertyChoices.forFilter(controller.catalog).map { property in
            PanelChoice(title: property.name, icon: CellKind.for(property.kind).symbol, identifier: "filter-by-\(property.name)") { [weak self] in
                var path: FilterPath?
                controller.editView { ops, viewId in path = try ops.addFilter(for: property.id, to: viewId) }
                if let path { self?.showFilter(at: path, below: rect, in: view) }
            }
        }
        let advanced = PanelChoice(title: "Расширенный фильтр", icon: "plus", identifier: "filter-by-advanced") { [weak self] in
            guard let self, let rule = AdvancedFilterModel.newRule(catalog: controller.catalog) else { return }
            var added: FilterPath = []
            controller.editView { ops, viewId in
                let (filter, path) = AdvancedFilterModel.addingAdvanced(rule, to: controller.view.filterNode)
                added = path
                try ops.setFilter(filter, of: viewId)
            }
            self.showFilter(at: added, below: rect, in: view)
        }
        let menu = ChoiceMenuView(choices: choices, footer: [advanced], searchPlaceholder: "Фильтр по…", identifier: "filter-property-list")
        showMenuInCard(menu, below: rect, in: view)
    }

    /// Окно плашки простого фильтра (path — путь в корне, [i]) или расширенного (путь группы [k]).
    public func showFilter(at path: FilterPath, below rect: NSRect, in view: NSView) {
        guard let node = FilterEditing.root(controller.view.filterNode).node(at: path) else { return }
        let page: PanelPage = node.isGroup ? AdvancedFilterPage(panels: self, groupPath: path) : SimpleFilterPage(panels: self, path: path)
        show(page, below: rect, in: view)
    }

    /// Сортировка: нет уровней — список свойств «Сортировать по…»; есть — окно уровней.
    public func showSorts(below rect: NSRect, in view: NSView) {
        guard controller.view.sortSpecs.isEmpty else { return show(SortPage(panels: self), below: rect, in: view) }
        let controller = controller
        let choices = PropertyChoices.forSort(controller.catalog, excluding: []).map { property in
            PanelChoice(title: property.name, icon: CellKind.for(property.kind).symbol, identifier: "sort-by-\(property.name)") { [weak self] in
                controller.editView { try $0.sort(by: property.id, ascending: true, in: $1) }
                self?.showSorts(below: rect, in: view)
            }
        }
        showMenuInCard(ChoiceMenuView(choices: choices, searchPlaceholder: "Сортировать по…", identifier: "sort-property-list"), below: rect, in: view)
    }

    public func showPropertyVisibility(below rect: NSRect, in view: NSView) {
        show(PropertyVisibilityPage(panels: self), below: rect, in: view)
    }

    public func showGrouping(below rect: NSRect, in view: NSView) {
        show(GroupingPage(panels: self), below: rect, in: view)
    }

    public func showLayout(below rect: NSRect, in view: NSView) {
        show(LayoutPage(panels: self), below: rect, in: view)
    }

    /// «Настройки вида» (ползунки, «•••» шапки): панель справа на высоту `host`, пункты переходят на свои страницы с «←».
    /// `selectName` — выделить имя (после «Дублировать вид»).
    public func showViewSettings(in host: NSView, selectName: Bool) {
        closeSettingsPanel()
        let panel = ViewSettingsPanel(panels: self)
        panel.onClose = { [weak self] in self?.closeSettingsPanel() }
        let width = min(PropertyPopupMetrics.panelWidth, host.bounds.width)
        panel.frame = NSRect(x: host.bounds.maxX - width, y: 0, width: width, height: host.bounds.height)
        panel.autoresizingMask = [.minXMargin, .height]
        host.addSubview(panel, positioned: .above, relativeTo: nil)
        panel.watchOutsideClicks()
        settingsPanel = panel
        if selectName { panel.selectName() }
    }

    public func close() {
        card.close()
        closeMenus(from: 1)
        closeSettingsPanel()
    }

    // MARK: Карточки

    private func show(_ page: PanelPage, below rect: NSRect, in view: NSView) {
        closeMenus(from: 1)
        anchor = (rect, view)
        page.onResize = { [weak self, weak page] in
            guard let self, let page, self.page === page else { return }
            self.card.resize(to: page.size)
        }
        page.onFinish = { [weak self] in self?.card.close() }
        page.rebuild()
        present(page, size: page.size, below: rect, in: view)
        self.page = page
        (page as? FocusablePage)?.focusFirstField()
    }

    private func showMenuInCard(_ menu: ChoiceMenuView, below rect: NSRect, in view: NSView) {
        closeMenus(from: 1)
        menu.onChosen = { [weak self] in self?.card.close() }
        menu.onCancel = { [weak self] in self?.card.close() }
        menu.onResize = { [weak self, weak menu] in
            guard let self, let menu else { return }
            self.card.resize(to: menu.size)
        }
        present(menu, size: menu.size, below: rect, in: view)
        page = nil
        menu.focus()
    }

    /// Карточка `content` под `rect` (координаты `view`), левым краем по нему; прежнее содержимое карточки заменяется.
    private func present(_ content: NSView, size: NSSize, below rect: NSRect, in view: NSView) {
        guard let windowContent = view.window?.contentView else { return }
        let anchorRect = view.convert(rect, to: nil)
        let point = NSPoint(x: anchorRect.minX, y: anchorRect.minY - Metrics.PopupMenu.anchorSpacing)
        page?.flush()
        swapping = true
        card.show(content, size: size, from: windowContent.convert(point, from: nil), in: windowContent)
        swapping = false
    }

    /// Выпадающий список уровня `level` под `anchor` (кнопкой окна).
    func showMenu(_ menu: ChoiceMenuView, below anchor: NSView, level: Int) {
        let menuCard = closeMenus(from: level)
        menu.onChosen = { [weak menuCard] in menuCard?.close() }
        menu.onCancel = { [weak menuCard] in menuCard?.close() }
        menu.onResize = { [weak menuCard, weak menu] in
            guard let menu else { return }
            menuCard?.resize(to: menu.size)
        }
        menuCard.show(menu, size: menu.size, below: anchor)
        menu.focus()
    }

    /// Окно значения правила расширенного фильтра под кнопкой значения.
    func showMenuPage(_ page: PanelPage, below anchor: NSView, level: Int) {
        let menuCard = closeMenus(from: level)
        page.menuLevel = level + 1
        page.onResize = { [weak menuCard, weak page] in
            guard let page else { return }
            menuCard?.resize(to: page.size)
        }
        page.onFinish = { [weak menuCard] in menuCard?.close() }
        page.rebuild()
        menuCard.show(page, size: page.size, below: anchor)
        menuPages[level] = page
        (page as? FocusablePage)?.focusFirstField()
    }

    /// Закрыть списки уровня `level` и выше; карточка уровня `level` — готова к показу.
    @discardableResult
    func closeMenus(from level: Int) -> PopupCard {
        for (key, menuCard) in menuCards where key >= level { menuCard.close() }
        let menuCard = menuCards[level] ?? PopupCard()
        if menuCards[level] == nil {
            menuCards[level] = menuCard
            menuCard.onClose = { [weak self] in
                guard let self else { return }
                self.menuPages[level]?.flush()
                self.menuPages[level] = nil
                for (key, other) in self.menuCards where key > level { other.close() }
            }
        }
        return menuCard
    }

    func closeCard() { card.close() }

    private func closeSettingsPanel() {
        guard let panel = settingsPanel else { return }
        settingsPanel = nil
        panel.flush()
        panel.stopWatching()
        panel.removeFromSuperview()
        closeMenus(from: 1)
    }

    private func databaseDidChange() {
        page?.reload()
        for level in menuPages.keys.sorted() { menuPages[level]?.reload() }
        settingsPanel?.reload()
    }

    /// Открытые окна — для проверок.
    var shownPage: PanelPage? { page }
    var currentAnchor: (rect: NSRect, view: NSView)? { anchor }
}

/// Страница с полем, которое получает фокус при открытии.
@MainActor
protocol FocusablePage: AnyObject {
    func focusFirstField()
}
