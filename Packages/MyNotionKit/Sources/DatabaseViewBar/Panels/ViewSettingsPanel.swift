import AppKit
import DatabaseGrid
import Databases
import NotesCore
import VisualStyle

/// «Настройки вида» (`notion-view-settings-panel.png`): панель справа на высоту видимой таблицы — поле имени вида, Раскладка ›,
/// Видимость свойств [N] ›, Фильтр ›, Сортировка ›, Группировка ›, —, Свойства ›. Пункт открывает свою страницу на месте
/// панели с «←»; «×», Esc и щелчок мимо закрывают.
@MainActor
final class ViewSettingsPanel: NSView {
    private unowned let panels: ViewPanels
    private var slot: ViewSettingsModel.Slot?
    private var header: PropertyPopupHeader?
    private var page: PanelPage?
    private let main = PropertyPopupStack()
    private var nameField: PropertyPopupField?
    private var valueRows: [ViewSettingsModel.Slot: PropertyPopupRow] = [:]
    private var monitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    var onClose: (() -> Void)?

    init(panels: ViewPanels) {
        self.panels = panels
        super.init(frame: .zero)
        setAccessibilityIdentifier("view-settings-panel")
        show(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    isolated deinit { stopWatching() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var controller: DatabaseTableController { panels.controller }

    override func layout() {
        super.layout()
        let content = NSRect(x: 1, y: 0, width: bounds.width - 1, height: bounds.height)
        header?.frame = NSRect(x: content.minX, y: 0, width: content.width, height: PropertyPopupMetrics.headerHeight)
        let below = NSRect(x: content.minX, y: PropertyPopupMetrics.headerHeight, width: content.width,
                           height: content.height - PropertyPopupMetrics.headerHeight)
        main.frame = below
        page?.frame = below
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.pageBackground.setFill()
        bounds.fill()
        Palette.border.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    /// Главная страница (`nil`) или страница пункта.
    private func show(_ next: ViewSettingsModel.Slot?) {
        window?.makeFirstResponder(self)
        commitName()
        page?.flush()
        page?.removeFromSuperview()
        page = nil
        header?.removeFromSuperview()
        main.removeFromSuperview()
        panels.closeMenus(from: 1)
        slot = next
        let header = PropertyPopupHeader(title: next.map(ViewSettingsModel.pageTitle) ?? "Настройки вида", showsBack: next != nil)
        header.onBack = { [weak self] in self?.show(nil) }
        header.onClose = { [weak self] in self?.onClose?() }
        self.header = header
        addSubview(header)
        if let next, let page = makePage(next) {
            page.onFinish = { [weak self] in self?.show(nil) }
            page.rebuild()
            self.page = page
            addSubview(page)
            (page as? FocusablePage)?.focusFirstField()
        } else {
            buildMain()
            addSubview(main)
        }
        needsLayout = true
    }

    /// Страница пункта; у «Свойств» своей нет — окно «Свойства» базы открывает `onShowProperties`.
    private func makePage(_ slot: ViewSettingsModel.Slot) -> PanelPage? {
        switch slot {
        case .layout: LayoutPage(panels: panels)
        case .visibility: PropertyVisibilityPage(panels: panels)
        case .filter: FilterListPage(panels: panels)
        case .sort: SortListPage(panels: panels)
        case .group: GroupingPage(panels: panels)
        case .properties: nil
        }
    }

    private func buildMain() {
        main.removeAll()
        valueRows = [:]
        let model = ViewSettingsModel(view: controller.view, catalog: controller.catalog)
        let field = PropertyPopupField(text: model.name, placeholder: "Название вида", icon: "tablecells", identifier: "view-settings-name")
        field.onEndEditing = { [weak self] _ in self?.commitName() }
        field.onCommand = { [weak self] command in
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                self?.commitName()
                self?.window?.makeFirstResponder(self)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                self?.onClose?()
                return true
            default:
                return false
            }
        }
        nameField = field
        main.append(field, height: PropertyPopupMetrics.nameBlockHeight)
        for row in model.rows {
            if row.slot == .properties { main.append(PropertyPopupSeparator(), height: PropertyPopupMetrics.separatorHeight) }
            let view = PropertyPopupRow(title: row.title, icon: row.icon, value: row.value, showsChevron: true, identifier: "view-settings-\(row.slot.rawValue)")
            view.onPress = { [weak self, weak view] in
                guard let self, let view else { return }
                if row.slot == .properties {
                    self.panels.onShowProperties?(view.bounds, view)
                } else {
                    self.show(row.slot)
                }
            }
            valueRows[row.slot] = view
            main.append(view, height: PropertyPopupMetrics.rowHeight)
        }
    }

    /// После правки базы: значения пунктов и имя (если поле не в фокусе) — на месте, страница пункта — по-своему.
    func reload() {
        if let page { return page.reload() }
        let model = ViewSettingsModel(view: controller.view, catalog: controller.catalog)
        for row in model.rows { valueRows[row.slot]?.value = row.value }
        if let nameField, !nameField.isFocused { nameField.field.stringValue = model.name }
    }

    func selectName() {
        guard let nameField else { return }
        nameField.focus()
        nameField.field.currentEditor()?.selectAll(nil)
    }

    func flush() {
        commitName()
        page?.flush()
    }

    private func commitName() {
        guard let nameField, slot == nil else { return }
        let name = nameField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != controller.view.name else { return }
        controller.editView { try $0.renameView($1, to: name) }
    }

    // MARK: Закрытие

    override func mouseDown(with event: NSEvent) {}

    override func cancelOperation(_ sender: Any?) { onClose?() }

    /// Щелчок мимо панели в её окне закрывает её (карточки окон — другие окна, их щелчки не считаются).
    func watchOutsideClicks(anchoredTo host: NSView) {
        stopWatching()
        guard let window = host.window else { return }
        let place: @MainActor @Sendable () -> Void = { [weak self, weak host, weak window] in
            guard let self, let window else { return }
            guard let host, host.window === window, host.superview != nil, !host.isHiddenOrHasHiddenAncestor,
                  let overlay = window.contentView else { self.onClose?(); return }
            // Таблица — documentView высотой во все строки. Ограничиваем панель видимым viewport.
            let visible = host.convert(host.visibleRect, to: overlay).intersection(overlay.bounds)
            guard !visible.isEmpty else { self.onClose?(); return }
            let width = min(PropertyPopupMetrics.panelWidth, visible.width)
            let target = NSRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height)
            if self.frame != target { self.frame = target }
        }
        place()
        window.makeFirstResponder(self)
        for name in [NSWindow.didResizeNotification, NSWindow.didUpdateNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { place() }
            })
        }
        windowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClose?() }
        })
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.onClose?() }
            return event
        }
    }

    func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
    }
}

/// Страница «Фильтр» в настройках вида (`notion-view-filters-panel.png`): плашки по порядку (щелчок — окно плашки),
/// «+ Добавить фильтр».
@MainActor
final class FilterListPage: PanelPage {
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    init(panels: ViewPanels) {
        super.init(panels: panels, width: PropertyPopupMetrics.panelWidth)
    }

    override func build() {
        let catalog = controller.catalog
        for (index, node) in FilterEditing.root(controller.view.filterNode).children.enumerated() {
            let title: String
            let icon: String
            if let condition = node.condition {
                title = FilterTexts.chipText(condition, catalog: catalog).text
                icon = catalog.propertiesById[condition.propertyId].map { CellKind.for($0.kind).symbol } ?? "line.3.horizontal.decrease"
            } else {
                title = FilterTexts.rules(node.ruleCount)
                icon = "line.3.horizontal.decrease"
            }
            _ = row(title, icon: icon, chevron: true, identifier: "view-settings-filter-\(index)") { [weak self] row in
                self?.panels.showFilter(at: [index], below: row.bounds, in: row)
            }
        }
        _ = row("Добавить фильтр", icon: "plus", identifier: "view-settings-add-filter") { [weak self] row in
            self?.panels.showAddFilter(below: row.bounds, in: row)
        }
    }
}

/// Страница «Сортировка» в настройках вида: уровни окна сортировки; без уровней — «+ Добавить сортировку».
@MainActor
final class SortListPage: PanelPage {
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    init(panels: ViewPanels) {
        super.init(panels: panels, width: PropertyPopupMetrics.panelWidth)
    }

    override func build() {
        let catalog = controller.catalog
        let model = SortPanelModel(view: controller.view, catalog: catalog)
        for level in model.levels {
            _ = row(level.property.name, icon: CellKind.for(level.property.kind).symbol, value: level.directionTitle, chevron: true,
                    identifier: "view-settings-sort-\(level.index)") { [weak self] row in
                self?.panels.showSorts(below: row.bounds, in: row)
            }
        }
        _ = row("Добавить сортировку", icon: "plus", identifier: "view-settings-add-sort") { [weak self] row in
            guard let self else { return }
            let choices = model.addChoices(catalog: catalog).map { choice in
                PanelChoice(title: choice.name, icon: CellKind.for(choice.kind).symbol) { [weak self] in
                    self?.edit { try $0.sort(by: choice.id, ascending: true, in: $1) }
                }
            }
            self.panels.showMenu(ChoiceMenuView(choices: choices, searchPlaceholder: "Сортировать по…"), below: row, level: self.menuLevel)
        }
    }
}
