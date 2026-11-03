import AppKit
import DatabaseGrid
import Databases
import NotesCore
import VisualStyle

/// Окно плашки простого фильтра (`notion-filter-select-popup.png`, `notion-filter-chip-menu.png`): «Свойство условие ▾»,
/// «•••» (Удалить фильтр, В расширенный фильтр), значение по типу.
@MainActor
final class SimpleFilterPage: PanelPage, FocusablePage {
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    let path: FilterPath
    private lazy var value = FilterValueSection(page: self, path: path)
    private var builtKey: String?

    init(panels: ViewPanels, path: FilterPath) {
        self.path = path
        super.init(panels: panels, width: PanelMetrics.windowWidth)
        setAccessibilityIdentifier("simple-filter-window")
    }

    private var condition: FilterCondition? { FilterEditing.root(controller.view.filterNode).node(at: path)?.condition }

    /// Свойство, условие и вид значения: другая — пересборка, иначе значение обновляется на месте.
    private func key(_ condition: FilterCondition) -> String {
        let editor = FilterValues.editor(for: condition, catalog: controller.catalog)
        return "\(condition.propertyId)|\(condition.op.rawValue)|\(FilterValueSection.shape(of: editor))"
    }

    override func build() {
        guard let condition, let property = controller.catalog.propertiesById[condition.propertyId] else { return }
        builtKey = key(condition)
        let header = PanelHStack()
        let name = NSTextField(labelWithString: property.name)
        name.font = PanelMetrics.font
        name.textColor = Palette.textSecondary
        name.lineBreakMode = .byTruncatingTail
        let nameWidth = min(ceil(name.intrinsicContentSize.width), 140)
        let op = PanelButton(title: FilterTexts.title(of: condition.op, kind: property.kind).lowercased(), identifier: "filter-operator")
        op.onPress = { [weak self] button in self?.showOperators(below: button) }
        let more = PanelIconButton(symbol: "ellipsis", label: "Ещё", identifier: "filter-more")
        more.onPress = { [weak self, weak more] in if let more { self?.showMore(below: more) } }
        header.add(name, .fixed(nameWidth), height: 18)
        header.add(op, .fixed(min(op.fittingWidth, width - nameWidth - 60)))
        header.add(NSView(), .flexible)
        header.add(more, .fixed(24), height: 24)
        stack.append(header, height: PanelMetrics.controlRowHeight)
        value.build(into: stack)
    }

    override func reload() {
        guard let condition else { return onFinish?() ?? () }
        if key(condition) != builtKey { return rebuild() }
        value.refresh()
    }

    override func flush() { value.flush() }

    func focusFirstField() { value.firstField?.focus() }

    private func showOperators(below button: PanelButton) {
        guard let condition, let property = controller.catalog.propertiesById[condition.propertyId] else { return }
        let catalog = controller.catalog
        let choices = FilterEditing.operators(for: property).map { op in
            PanelChoice(title: FilterTexts.title(of: op, kind: property.kind), isChecked: op == condition.op, identifier: "filter-op-\(op.rawValue)") { [weak self] in
                self?.value.flush()
                self?.panels.updateCondition(at: self?.path ?? []) { $0 = FilterValues.changingOperator($0, to: op, catalog: catalog) }
            }
        }
        panels.showMenu(ChoiceMenuView(choices: choices, identifier: "filter-operator-menu"), below: button, level: menuLevel)
    }

    private func showMore(below anchor: NSView) {
        let path = path
        let choices = [
            PanelChoice(title: "Удалить фильтр", icon: "trash", isDestructive: true, identifier: "filter-delete") { [weak self] in
                guard let self else { return }
                self.value.flush()
                self.panels.setFilter(FilterEditing.remove(at: path, in: self.controller.view.filterNode))
                self.onFinish?()
            },
            PanelChoice(title: "В расширенный фильтр", icon: "line.3.horizontal.decrease.circle", identifier: "filter-to-advanced") { [weak self] in
                guard let self else { return }
                self.value.flush()
                let (filter, advanced) = FilterEditing.moveToAdvanced(at: path, in: self.controller.view.filterNode)
                self.panels.setFilter(filter)
                self.panels.reshowFilter(at: advanced)
            },
        ]
        panels.showMenu(ChoiceMenuView(choices: choices, identifier: "filter-more-menu"), below: anchor, level: menuLevel)
    }
}

/// Окно значения правила расширенного фильтра под кнопкой значения.
@MainActor
final class FilterValuePage: PanelPage, FocusablePage {
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    private let path: FilterPath
    private lazy var value = FilterValueSection(page: self, path: path)

    init(panels: ViewPanels, path: FilterPath) {
        self.path = path
        super.init(panels: panels, width: PanelMetrics.windowWidth)
    }

    override func build() { value.build(into: stack) }

    override func reload() {
        guard let condition = FilterEditing.root(controller.view.filterNode).node(at: path)?.condition else { return onFinish?() ?? () }
        if FilterValueSection.shape(of: FilterValues.editor(for: condition, catalog: controller.catalog)) != value.shape { return rebuild() }
        value.refresh()
    }

    override func flush() { value.flush() }
    func focusFirstField() { value.firstField?.focus() }
}

/// Расширенный фильтр (`notion-advanced-filter-*.png`): строки «Где / И ▾ / И [свойство ▾] [условие ▾] [значение] [•••]»,
/// вложенная группа — с отступом и рамкой, «+ Добавить правило ▾», «Удалить фильтр».
@MainActor
final class AdvancedFilterPage: PanelPage, FocusablePage {
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    let groupPath: FilterPath
    private var signature: FilterNode?
    private var writers: [PausedWriter] = []
    private var inlineFields: [(path: FilterPath, field: PropertyPopupField)] = []

    init(panels: ViewPanels, groupPath: FilterPath) {
        self.groupPath = groupPath
        super.init(panels: panels, width: PanelMetrics.advancedWidth)
        setAccessibilityIdentifier("advanced-filter-window")
    }

    private var filter: FilterNode? { controller.view.filterNode }

    override func build() {
        writers = []
        inlineFields = []
        guard let group = AdvancedFilterModel.group(at: groupPath, in: filter) else { return }
        signature = AdvancedFilterModel.layoutSignature(FilterEditing.root(filter).node(at: groupPath), catalog: controller.catalog)
        append(group, to: stack)
        separator()
        _ = row("Удалить фильтр", icon: "trash", identifier: "advanced-filter-delete") { [weak self] _ in
            guard let self else { return }
            self.flush()
            self.panels.setFilter(FilterEditing.remove(at: self.groupPath, in: self.filter))
            self.onFinish?()
        }
    }

    override func reload() {
        let node = FilterEditing.root(filter).node(at: groupPath)
        guard node?.isGroup == true else { return onFinish?() ?? () }
        if AdvancedFilterModel.layoutSignature(node, catalog: controller.catalog) != signature { return rebuild() }
        for (path, field) in inlineFields where !field.isFocused {
            field.field.stringValue = FilterEditing.root(filter).node(at: path)?.condition.map(Self.inlineText) ?? ""
        }
    }

    override func flush() { writers.forEach { $0.flush() } }

    func focusFirstField() {}

    /// Строки группы и «+ Добавить правило ▾» в столбик `stack`.
    private func append(_ group: AdvancedFilterModel.Group, to stack: PropertyPopupStack) {
        for entry in group.entries {
            let row = PanelHStack()
            row.add(lead(entry.lead, group: group), .fixed(64))
            switch entry.content {
            case .rule(let condition):
                addRuleControls(condition, path: entry.path, to: row)
                row.add(actionsButton(entry), .fixed(24), height: 24)
                stack.append(row, height: PanelMetrics.controlRowHeight)
            case .group(let nested):
                let box = AdvancedGroupBox()
                append(nested, to: box.stack)
                row.add(box, .flexible, height: nil)
                row.add(actionsButton(entry), .fixed(24), height: 24)
                stack.append(row, height: box.stack.contentHeight + 8)
            }
        }
        let add = PanelButton(title: "Добавить правило", icon: "plus", identifier: "advanced-filter-add-\(group.path.count)")
        add.onPress = { [weak self] button in self?.showAddMenu(for: group, below: button) }
        let addRow = PanelHStack()
        addRow.add(add, .fixed(add.fittingWidth))
        stack.append(addRow, height: PanelMetrics.controlRowHeight)
    }

    private func lead(_ lead: AdvancedFilterModel.Lead, group: AdvancedFilterModel.Group) -> NSView {
        switch lead {
        case .whereLabel, .joinerText:
            let text: String = if case .joinerText(let isOr) = lead { AdvancedFilterModel.joinerTitle(isOr: isOr) } else { "Где" }
            let label = NSTextField(labelWithString: text)
            label.font = PanelMetrics.font
            label.textColor = Palette.textSecondary
            label.alignment = .right
            let box = PanelHStack()
            box.leading = 0
            box.trailing = 8
            box.add(label, .flexible, height: 18)
            return box
        case .joinerMenu(let isOr):
            let button = PanelButton(title: AdvancedFilterModel.joinerTitle(isOr: isOr), bordered: true, identifier: "advanced-filter-joiner")
            button.onPress = { [weak self] button in
                guard let self else { return }
                let choices = AdvancedFilterModel.joinerChoices.map { choice in
                    PanelChoice(title: choice.title, caption: choice.caption, isChecked: choice.isOr == isOr) { [weak self] in
                        guard let self else { return }
                        self.panels.setFilter(FilterEditing.setJoiner(or: choice.isOr, ofGroup: group.path, in: self.filter))
                    }
                }
                self.panels.showMenu(ChoiceMenuView(choices: choices, width: 260), below: button, level: self.menuLevel)
            }
            return button
        }
    }

    private func addRuleControls(_ condition: FilterCondition, path: FilterPath, to row: PanelHStack) {
        let catalog = controller.catalog
        guard let property = catalog.propertiesById[condition.propertyId] else { return }
        let propertyButton = PanelButton(title: property.name, icon: CellKind.for(property.kind).symbol, bordered: true, identifier: "advanced-filter-property")
        propertyButton.onPress = { [weak self] button in
            guard let self else { return }
            let choices = PropertyChoices.forFilter(catalog).map { choice in
                PanelChoice(title: choice.name, icon: CellKind.for(choice.kind).symbol, isChecked: choice.id == property.id) { [weak self] in
                    self?.panels.updateCondition(at: path) { $0 = FilterValues.changingProperty($0, to: choice) }
                }
            }
            self.panels.showMenu(ChoiceMenuView(choices: choices, searchPlaceholder: "Найти свойство"), below: button, level: self.menuLevel)
        }
        row.add(propertyButton, .fixed(160))
        let opButton = PanelButton(title: FilterTexts.title(of: condition.op, kind: property.kind), bordered: true, identifier: "advanced-filter-operator")
        opButton.onPress = { [weak self] button in
            guard let self else { return }
            let choices = FilterEditing.operators(for: property).map { op in
                PanelChoice(title: FilterTexts.title(of: op, kind: property.kind), isChecked: op == condition.op) { [weak self] in
                    self?.panels.updateCondition(at: path) { $0 = FilterValues.changingOperator($0, to: op, catalog: catalog) }
                }
            }
            self.panels.showMenu(ChoiceMenuView(choices: choices), below: button, level: self.menuLevel)
        }
        row.add(opButton, .fixed(200))
        let editor = FilterValues.editor(for: condition, catalog: catalog)
        switch editor {
        case .none:
            row.add(NSView(), .flexible)
        case .text, .number:
            let isNumber = if case .number = editor { true } else { false }
            let field = PropertyPopupField(text: Self.inlineText(condition), placeholder: "Значение", identifier: "advanced-filter-value")
            let writer = PausedWriter()
            writers.append(writer)
            field.onChange = { [weak self] text in
                writer.schedule { [weak self] in
                    self?.panels.updateCondition(at: path) { $0.value = isNumber ? FilterValues.number(text) : FilterValues.text(text) }
                }
            }
            field.onEndEditing = { _ in writer.flush() }
            inlineFields.append((path, field))
            row.add(field, .flexible, height: nil)
        default:
            let text = FilterTexts.valueText(condition, catalog: catalog)
            let valueButton = PanelButton(title: text ?? "Значение", bordered: true, identifier: "advanced-filter-value")
            valueButton.isPlaceholder = text == nil
            valueButton.onPress = { [weak self] button in
                guard let self else { return }
                self.panels.showMenuPage(FilterValuePage(panels: self.panels, path: path), below: button, level: self.menuLevel)
            }
            row.add(valueButton, .flexible)
        }
    }

    static func inlineText(_ condition: FilterCondition) -> String {
        condition.value.string ?? condition.value.number.map(FilterValues.plain) ?? ""
    }

    private func actionsButton(_ entry: AdvancedFilterModel.Entry) -> PanelIconButton {
        let button = PanelIconButton(symbol: "ellipsis", label: "Ещё", identifier: "advanced-filter-more")
        button.onPress = { [weak self, weak button] in
            guard let self, let button else { return }
            let choices = entry.actions.map { action in
                PanelChoice(title: action.title, icon: action.icon, isDestructive: action == .remove, identifier: "advanced-filter-\(action.rawValue)") { [weak self] in
                    guard let self else { return }
                    self.flush()
                    self.panels.setFilter(AdvancedFilterModel.apply(action, at: entry.path, in: self.filter))
                }
            }
            self.panels.showMenu(ChoiceMenuView(choices: choices), below: button, level: self.menuLevel)
        }
        return button
    }

    private func showAddMenu(for group: AdvancedFilterModel.Group, below button: PanelButton) {
        guard let rule = AdvancedFilterModel.newRule(catalog: controller.catalog) else { return }
        var choices = [PanelChoice(title: "Добавить правило", icon: "plus", identifier: "advanced-filter-add-rule") { [weak self] in
            guard let self else { return }
            self.flush()
            self.panels.setFilter(FilterEditing.addRule(rule, toGroup: group.path, in: self.filter))
        }]
        if group.canAddGroup {
            choices.append(PanelChoice(title: "Добавить группу фильтров", caption: "Чтобы вложить другие фильтры", icon: "square.dashed",
                                       identifier: "advanced-filter-add-group") { [weak self] in
                guard let self else { return }
                self.flush()
                self.panels.setFilter(FilterEditing.addGroup(rule, toGroup: group.path, in: self.filter))
            })
        }
        panels.showMenu(ChoiceMenuView(choices: choices, width: 260), below: button, level: menuLevel)
    }
}

/// Вложенная группа расширенного фильтра: рамка со скруглением, строки внутри.
@MainActor
final class AdvancedGroupBox: NSView {
    let stack = PropertyPopupStack()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.topPadding = 4
        stack.bottomPadding = 4
        addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        // Цвет палитры уже содержит прозрачность (5% / 5,5%): замена её на 40% затемняет всю группу.
        Palette.hoverBackground.setFill()
        let path = NSBezierPath(roundedRect: box, xRadius: Metrics.PopupMenu.rowCornerRadius, yRadius: Metrics.PopupMenu.rowCornerRadius)
        path.fill()
        Palette.searchFieldBorder.setStroke()
        path.stroke()
    }
}

extension ViewPanels {
    /// Окно фильтра на месте прежнего (после «В расширенный фильтр»).
    func reshowFilter(at path: FilterPath) {
        guard let anchor = currentAnchor else { return }
        showFilter(at: path, below: anchor.rect, in: anchor.view)
    }
}
