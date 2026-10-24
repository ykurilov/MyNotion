import AppKit
import DatabaseGrid
import Databases
import NotesCore
import VisualStyle

/// Значение условия в окне фильтра (`notion-filter-select-popup.png`, `notion-filter-date-*.png`): поле текста и числа,
/// поиск и флажки вариантов, флажок, дата словами или точная, «Между», «Относительно сегодня». Поля пишут после паузы
/// или при уходе из поля; после правки базы обновляется на месте — поле в фокусе не теряет ввод.
@MainActor
final class FilterValueSection {
    private unowned let page: PanelPage
    private let path: FilterPath
    private let writer = PausedWriter()
    private var fields: [PropertyPopupField] = []
    private var buttons: [String: PanelButton] = [:]
    private var list: PropertyPopupStack?
    private var query = ""
    private(set) var shape = ""

    init(page: PanelPage, path: FilterPath) {
        self.page = page
        self.path = path
    }

    private var panels: ViewPanels { page.panels }
    private var condition: FilterCondition? { FilterEditing.root(panels.controller.view.filterNode).node(at: path)?.condition }
    private var editor: FilterValueEditor {
        condition.map { FilterValues.editor(for: $0, catalog: panels.controller.catalog, query: query) } ?? .none
    }

    /// Вид раскладки значения: другая — окно пересобирается.
    static func shape(of editor: FilterValueEditor) -> String {
        switch editor {
        case .none: "none"
        case .text: "text"
        case .number: "number"
        case .options: "options"
        case .statusGroup: "group"
        case .checkbox: "checkbox"
        case .date(.exact): "date-exact"
        case .date: "date"
        case .dateRange: "range"
        case .relative(let direction, _, _): direction == "this" ? "relative-this" : "relative"
        }
    }

    var firstField: PropertyPopupField? { fields.first }

    func flush() { writer.flush() }

    /// Строки значения в столбик страницы.
    func build(into stack: PropertyPopupStack) {
        fields = []
        buttons = [:]
        list = nil
        let editor = editor
        shape = Self.shape(of: editor)
        switch editor {
        case .none:
            break
        case .text(let text):
            stack.append(field(text, placeholder: "Значение", identifier: "filter-value-text") { FilterValues.text($0) }, height: PropertyPopupMetrics.nameBlockHeight)
        case .number(let text):
            stack.append(field(text, placeholder: "Число", identifier: "filter-value-number") { FilterValues.number($0) }, height: PropertyPopupMetrics.nameBlockHeight)
        case .options:
            if condition?.op != .isInGroup {
                let search = PropertyPopupField(text: query, placeholder: "Выберите один или несколько вариантов…", identifier: "filter-value-search")
                search.onChange = { [weak self] text in
                    self?.query = text
                    self?.refreshList()
                }
                fields.append(search)
                stack.append(search, height: PropertyPopupMetrics.nameBlockHeight)
            }
            appendList(to: stack)
        case .statusGroup, .checkbox:
            appendList(to: stack)
        case .date(let choice):
            let button = PanelButton(title: Self.dateChoiceTitle(choice), bordered: true, identifier: "filter-value-date")
            button.isPlaceholder = choice == .unset
            button.onPress = { [weak self] button in self?.showDateChoices(below: button) }
            buttons["date"] = button
            let row = PanelHStack()
            row.add(button, .flexible)
            stack.append(row, height: PanelMetrics.controlRowHeight)
            if case .exact(let day) = choice {
                stack.append(dayField(day, identifier: "filter-value-exact") { FilterValues.exactDate($0) }, height: PropertyPopupMetrics.nameBlockHeight)
            }
        case .dateRange(let start, let end):
            let row = PanelHStack()
            let first = dayField(start, identifier: "filter-value-start") { [weak self] _ in self?.rangeValue() }
            let second = dayField(end, identifier: "filter-value-end") { [weak self] _ in self?.rangeValue() }
            let dash = NSTextField(labelWithString: "–")
            dash.textColor = Palette.textSecondary
            row.leading = 0
            row.trailing = 0
            row.add(first, .flexible, height: nil)
            row.add(dash, .fixed(10), height: 18)
            row.add(second, .flexible, height: nil)
            stack.append(row, height: PropertyPopupMetrics.nameBlockHeight)
        case .relative(let direction, let count, let unit):
            let row = PanelHStack()
            let directionButton = PanelButton(title: Self.title(direction, in: FilterTexts.relativeDirections), bordered: true, identifier: "filter-value-direction")
            directionButton.onPress = { [weak self] button in
                self?.showChoices(FilterTexts.relativeDirections, current: direction, below: button) { key, value in
                    FilterValues.relative(direction: key, count: Int(value["count"]?.number ?? 1), unit: value["unit"]?.string ?? "week")
                }
            }
            let unitButton = PanelButton(title: Self.title(unit, in: FilterTexts.relativeUnits).lowercased(), bordered: true, identifier: "filter-value-unit")
            unitButton.onPress = { [weak self] button in
                self?.showChoices(FilterTexts.relativeUnits, current: unit, below: button) { key, value in
                    FilterValues.relative(direction: value["direction"]?.string ?? "this", count: Int(value["count"]?.number ?? 1), unit: key)
                }
            }
            buttons["direction"] = directionButton
            buttons["unit"] = unitButton
            row.add(directionButton, .flexible)
            if direction != "this" {
                let countField = field("\(count)", placeholder: "N", identifier: "filter-value-count") { [weak self] text in
                    let value = self?.condition?.value ?? .null
                    return FilterValues.relative(direction: value["direction"]?.string ?? "past", count: Int(text) ?? 1, unit: value["unit"]?.string ?? "week")
                }
                row.add(countField, .fixed(64), height: nil)
            }
            row.add(unitButton, .flexible)
            stack.append(row, height: PropertyPopupMetrics.nameBlockHeight)
        }
    }

    /// После правки базы: подписи и списки — на месте; поля без фокуса — новое значение (⌘Z).
    func refresh() {
        let editor = editor
        switch editor {
        case .text(let text), .number(let text):
            if let field = fields.first, !field.isFocused { field.field.stringValue = text }
        case .options, .statusGroup, .checkbox:
            refreshList()
        case .date(let choice):
            buttons["date"]?.title = Self.dateChoiceTitle(choice)
            buttons["date"]?.isPlaceholder = choice == .unset
            if case .exact(let day) = choice, let field = fields.first, !field.isFocused { field.field.stringValue = day }
        case .dateRange(let start, let end):
            for (field, text) in zip(fields, [start, end]) where !field.isFocused { field.field.stringValue = text }
        case .relative(let direction, let count, let unit):
            buttons["direction"]?.title = Self.title(direction, in: FilterTexts.relativeDirections)
            buttons["unit"]?.title = Self.title(unit, in: FilterTexts.relativeUnits).lowercased()
            if let field = fields.first, !field.isFocused { field.field.stringValue = "\(count)" }
        case .none:
            break
        }
    }

    // MARK: Списки

    private func appendList(to stack: PropertyPopupStack) {
        let list = PropertyPopupStack()
        list.topPadding = 0
        list.bottomPadding = 0
        self.list = list
        fillList()
        stack.append(list, height: list.contentHeight, inset: 0)
    }

    private func refreshList() {
        guard let list else { return }
        list.removeAll()
        fillList()
        page.resizeRow(list, to: list.contentHeight)
    }

    private func fillList() {
        guard let list else { return }
        var choices: [PanelChoice] = []
        switch editor {
        case .options(let items):
            choices = items.map { item in
                PanelChoice(title: item.name, icon: item.isSelected ? "checkmark.square.fill" : "square", chip: item.color,
                            identifier: "filter-option-\(item.name)") { [weak self] in
                    self?.write { FilterValues.toggling(item.id, in: $0.value) }
                }
            }
            if choices.isEmpty { list.append(PropertyPopupCaption(query.isEmpty ? "Вариантов нет" : "Ничего не найдено"), height: PropertyPopupMetrics.captionHeight) }
        case .statusGroup(let selected):
            choices = FilterValues.statusGroups.map { group in
                PanelChoice(title: group.title, isChecked: group.group == selected, identifier: "filter-group-\(group.group.rawValue)") { [weak self] in
                    self?.write { _ in FilterValues.statusGroup(group.group) }
                }
            }
        case .checkbox(let checked):
            choices = [(true, "Отмечено"), (false, "Не отмечено")].map { value, title in
                PanelChoice(title: title, icon: value ? "checkmark.square.fill" : "square", isChecked: checked == value,
                            identifier: "filter-checkbox-\(value)") { [weak self] in
                    self?.write { _ in .bool(value) }
                }
            }
        default:
            break
        }
        for choice in choices {
            let row = ChoiceRowView(choice)
            row.onPress = { choice.perform() }
            list.append(row, height: PropertyPopupMetrics.rowHeight)
        }
    }

    // MARK: Поля

    private func field(_ text: String, placeholder: String, identifier: String, value: @escaping (String) -> JSONValue?) -> PropertyPopupField {
        let field = PropertyPopupField(text: text, placeholder: placeholder, identifier: identifier)
        field.onChange = { [weak self] text in
            self?.writer.schedule { [weak self] in
                guard let value = value(text) else { return }
                self?.write { _ in value }
            }
        }
        field.onEndEditing = { [weak self] _ in self?.writer.flush() }
        field.onCommand = { [weak self] command in
            guard command == #selector(NSResponder.insertNewline(_:)) else { return false }
            self?.writer.flush()
            return true
        }
        fields.append(field)
        return field
    }

    private func dayField(_ text: String, identifier: String, value: @escaping (String) -> JSONValue?) -> PropertyPopupField {
        field(text, placeholder: "ГГГГ-ММ-ДД", identifier: identifier, value: value)
    }

    private func rangeValue() -> JSONValue? {
        guard fields.count >= 2 else { return nil }
        return FilterValues.dateRange(start: fields[0].text, end: fields[1].text)
    }

    private func write(_ value: @escaping (FilterCondition) -> JSONValue) {
        panels.updateCondition(at: path) { $0.value = value($0) }
    }

    // MARK: Меню

    private func showDateChoices(below button: PanelButton) {
        let current: String? = switch editor {
        case .date(.relative(let key)): key
        case .date(.exact): "exact"
        default: nil
        }
        let choices = FilterValues.dateChoices.map { choice in
            PanelChoice(title: choice.title, isChecked: choice.key == current, identifier: "filter-date-\(choice.key)") { [weak self] in
                if choice.key == "exact", current == "exact" { return }
                self?.write { _ in FilterValues.dateChoice(choice.key) }
            }
        }
        panels.showMenu(ChoiceMenuView(choices: choices, identifier: "filter-date-menu"), below: button, level: page.menuLevel)
    }

    private func showChoices(_ items: [(key: String, title: String)], current: String, below button: PanelButton,
                             value: @escaping (String, JSONValue) -> JSONValue) {
        let choices = items.map { item in
            PanelChoice(title: item.title, isChecked: item.key == current) { [weak self] in
                self?.write { value(item.key, $0.value) }
            }
        }
        panels.showMenu(ChoiceMenuView(choices: choices), below: button, level: page.menuLevel)
    }

    static func dateChoiceTitle(_ choice: FilterDateChoice) -> String {
        switch choice {
        case .unset: "Выберите дату"
        case .relative(let key): title(key, in: FilterTexts.relativeDates)
        case .exact: "Точная дата"
        }
    }

    static func title(_ key: String, in items: [(key: String, title: String)]) -> String { items.first { $0.key == key }?.title ?? key }
}

extension ViewPanels {
    /// Правка условия фильтра по пути одним шагом.
    func updateCondition(at path: FilterPath, _ edit: (inout FilterCondition) -> Void) {
        let controller = controller
        controller.editView { ops, viewId in try ops.setFilter(FilterEditing.update(at: path, in: controller.view.filterNode, edit), of: viewId) }
    }

    /// Новое дерево фильтра одним шагом.
    func setFilter(_ filter: FilterNode?) {
        controller.editView { try $0.setFilter(filter, of: $1) }
    }
}
