import AppKit
import DatabaseGrid
import Databases
import NotesCore
import VisualStyle

/// Окно сортировки (`notion-sort-popup.png`, `notion-sort-two-levels.png`): «⠿ [свойство ▾] [направление ▾] ✕»,
/// «+ Добавить сортировку», «Удалить сортировку» (снимает все уровни). Уровни перетаскиваются за ручку.
@MainActor
final class SortPage: PanelPage {
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    private var levelRows: [NSView] = []

    init(panels: ViewPanels) {
        super.init(panels: panels, width: PanelMetrics.sortWidth)
        setAccessibilityIdentifier("sort-window")
    }

    override func build() {
        levelRows = []
        let catalog = controller.catalog
        let model = SortPanelModel(view: controller.view, catalog: catalog)
        guard !model.levels.isEmpty else { return onFinish?() ?? () }
        for level in model.levels {
            let row = PanelHStack()
            row.leading = 0
            let handle = DragHandleView()
            handle.onDrag = { [weak self] event in self?.drag(level.index, startingWith: event) }
            row.add(handle, .fixed(16), height: nil)
            let property = PanelButton(title: level.property.name, icon: CellKind.for(level.property.kind).symbol, bordered: true,
                                       identifier: "sort-level-property-\(level.index)")
            property.onPress = { [weak self] button in
                guard let self else { return }
                let choices = model.propertyChoices(forLevel: level.index, catalog: catalog).map { choice in
                    PanelChoice(title: choice.name, icon: CellKind.for(choice.kind).symbol, isChecked: choice.id == level.property.id) { [weak self] in
                        self?.edit { try $0.setSorts(model.replacingProperty(atLevel: level.index, with: choice.id), of: $1) }
                    }
                }
                self.panels.showMenu(ChoiceMenuView(choices: choices, searchPlaceholder: "Найти свойство"), below: button, level: self.menuLevel)
            }
            row.add(property, .flexible)
            let direction = PanelButton(title: level.directionTitle, bordered: true, identifier: "sort-level-direction-\(level.index)")
            direction.onPress = { [weak self] button in
                guard let self else { return }
                let choices = SortPanelModel.directions(for: level.property.kind).map { option in
                    PanelChoice(title: option.title, isChecked: option.ascending == level.ascending) { [weak self] in
                        self?.edit { try $0.setSorts(model.settingDirection(atLevel: level.index, ascending: option.ascending), of: $1) }
                    }
                }
                self.panels.showMenu(ChoiceMenuView(choices: choices, width: 200), below: button, level: self.menuLevel)
            }
            row.add(direction, .fixed(150))
            let remove = PanelIconButton(symbol: "xmark", label: "Убрать сортировку", identifier: "sort-level-remove-\(level.index)")
            remove.onPress = { [weak self] in self?.edit { try $0.removeSort(at: level.index, in: $1) } }
            row.add(remove, .fixed(24), height: 24)
            levelRows.append(row)
            stack.append(row, height: PanelMetrics.controlRowHeight)
        }
        _ = row("Добавить сортировку", icon: "plus", identifier: "sort-add") { [weak self] row in
            guard let self else { return }
            let choices = model.addChoices(catalog: catalog).map { choice in
                PanelChoice(title: choice.name, icon: CellKind.for(choice.kind).symbol, identifier: "sort-by-\(choice.name)") { [weak self] in
                    self?.edit { try $0.sort(by: choice.id, ascending: true, in: $1) }
                }
            }
            self.panels.showMenu(ChoiceMenuView(choices: choices, searchPlaceholder: "Сортировать по…", identifier: "sort-add-property-list"), below: row, level: self.menuLevel)
        }
        _ = row("Удалить сортировку", icon: "trash", destructive: true, identifier: "sort-delete") { [weak self] _ in
            self?.edit { try $0.removeAllSorts(in: $1) }
            self?.onFinish?()
        }
    }

    private func drag(_ index: Int, startingWith event: NSEvent) {
        guard let insertion = RowDrag.track(rows: levelRows, in: stack, startingWith: event) else { return }
        let destination = SortPanelModel.moveDestination(from: index, insertion: insertion)
        guard destination != index else { return }
        edit { try $0.moveSort(from: index, to: destination, in: $1) }
    }
}

/// «Видимость свойств» (`notion-view-property-visibility.png`): поиск; «Показаны в таблице · Скрыть все» с ручками
/// (порядок колонок) и глазами; «Скрыты в таблице · Показать все»; «Название» без глаза.
@MainActor
final class PropertyVisibilityPage: PanelPage, FocusablePage {
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    private let search = PropertyPopupField(text: "", placeholder: "Найти свойство", searchGlyph: true, identifier: "visibility-search")
    private let list = PropertyPopupStack()
    private var query = ""
    private var shownRows: [NSView] = []

    init(panels: ViewPanels) {
        super.init(panels: panels, width: PanelMetrics.windowWidth)
        setAccessibilityIdentifier("visibility-window")
        list.topPadding = 0
        list.bottomPadding = 0
        search.onChange = { [weak self] text in
            self?.query = text
            self?.reload()
        }
    }

    override func build() {
        stack.append(search, height: PropertyPopupMetrics.searchBlockHeight)
        fillList()
        stack.append(list, height: list.contentHeight, inset: 0)
    }

    /// Поиск остаётся на месте: пересобирается только список.
    override func reload() {
        guard search.superview != nil else { return rebuild() }
        list.removeAll()
        fillList()
        resizeRow(list, to: list.contentHeight)
    }

    func focusFirstField() { search.focus() }

    private func fillList() {
        shownRows = []
        let model = PropertyVisibilityModel(view: controller.view, catalog: controller.catalog, query: query)
        let hideAll = PanelLinkButton(title: "Скрыть все", identifier: "visibility-hide-all")
        hideAll.onPress = { [weak self] in self?.edit { try $0.setAllVisible(false, in: $1) } }
        hideAll.isHidden = !model.canHideAll
        list.append(PanelCaptionRow("Показаны в таблице", link: hideAll), height: PropertyPopupMetrics.captionHeight)
        for item in model.shown {
            let eye: PanelIconButton? = item.isTitle ? nil : PanelIconButton(symbol: "eye", label: "Скрыть", identifier: "visibility-hide-\(item.property.name)")
            eye?.onPress = { [weak self] in self?.edit { try $0.setVisible(item.property.id, false, in: $1) } }
            let row = PanelHandleRow(label: .text(item.property.name, icon: item.symbol), trailing: eye, showsHandle: !item.isTitle,
                                     identifier: "visibility-shown-\(item.property.name)")
            row.onDrag = { [weak self] event in self?.drag(item.property.id, startingWith: event, model: model) }
            shownRows.append(row)
            list.append(row, height: PropertyPopupMetrics.rowHeight)
        }
        guard !model.hidden.isEmpty else { return }
        let showAll = PanelLinkButton(title: "Показать все", identifier: "visibility-show-all")
        showAll.onPress = { [weak self] in self?.edit { try $0.setAllVisible(true, in: $1) } }
        list.append(PanelCaptionRow("Скрыты в таблице", link: showAll), height: PropertyPopupMetrics.captionHeight)
        for item in model.hidden {
            let eye = PanelIconButton(symbol: "eye.slash", label: "Показать", identifier: "visibility-show-\(item.property.name)")
            eye.onPress = { [weak self] in self?.edit { try $0.setVisible(item.property.id, true, in: $1) } }
            list.append(PanelHandleRow(label: .text(item.property.name, icon: item.symbol), trailing: eye, showsHandle: false,
                                       identifier: "visibility-hidden-\(item.property.name)"), height: PropertyPopupMetrics.rowHeight)
        }
    }

    private func drag(_ propertyId: UUID, startingWith event: NSEvent, model: PropertyVisibilityModel) {
        // При поиске видна часть колонок: место считается по полному списку только без поиска.
        guard query.isEmpty, let insertion = RowDrag.track(rows: shownRows, in: list, startingWith: event),
              let index = model.moveIndex(of: propertyId, insertion: insertion) else { return }
        edit { try $0.moveColumn(propertyId, in: $1, to: index) }
    }
}
