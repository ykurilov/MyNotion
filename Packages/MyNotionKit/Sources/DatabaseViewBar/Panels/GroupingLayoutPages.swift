import AppKit
import DatabaseGrid
import Databases
import NotesCore
import VisualStyle

/// Окно группировки (`notion-group-settings.png`, `notion-group-by-list.png`, `notion-group-sort-options.png`):
/// «Группировать по ›», «Сортировка ›», шаг по типу, «Скрывать пустые группы», «Группы · Скрыть все» с ручками и глазами,
/// «Убрать группировку». Без группировки — сразу список «Группировать по».
@MainActor
final class GroupingPage: PanelPage {
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    private var groupRows: [NSView] = []
    private var builtKey: String?
    private var numberFields: [PropertyPopupField] = []

    init(panels: ViewPanels) {
        super.init(panels: panels, width: PanelMetrics.windowWidth)
        setAccessibilityIdentifier("grouping-window")
    }

    private var model: GroupingPanelModel {
        GroupingPanelModel(view: controller.view, catalog: controller.catalog, groups: controller.groups)
    }

    /// Шаг числа не входит: поля в фокусе не теряют ввод.
    private func key(_ model: GroupingPanelModel) -> String {
        var settings = model.settings
        if case .number = model.bucket { settings?.bucket = nil }
        return "\(String(describing: settings?.json))|\(model.groups)"
    }

    override func build() {
        groupRows = []
        numberFields = []
        let model = self.model
        builtKey = key(model)
        guard let property = model.property, let settings = model.settings else { return buildPropertyList(current: nil) }
        _ = row("Группировать по", icon: nil, value: property.name, chevron: true, identifier: "group-by") { [weak self] row in
            self?.showPropertyMenu(current: property.id, below: row)
        }
        _ = row("Сортировка", icon: nil, value: model.sortTitle, chevron: true, identifier: "group-sort") { [weak self] row in
            guard let self else { return }
            let choices = GroupingPanelModel.sortChoices.map { choice in
                PanelChoice(title: choice.title, isChecked: choice.sort == settings.groupSort) { [weak self] in
                    self?.editGroup { $0.groupSort = choice.sort }
                }
            }
            self.panels.showMenu(ChoiceMenuView(choices: choices), below: row, level: self.menuLevel)
        }
        switch model.bucket {
        case .none:
            break
        case .date(let selected):
            _ = row("Шаг", icon: nil, value: GroupingPanelModel.dateBucketTitle(selected), chevron: true, identifier: "group-bucket") { [weak self] row in
                guard let self else { return }
                let choices = GroupingPanelModel.dateBuckets.map { bucket in
                    PanelChoice(title: bucket.title, isChecked: bucket.key == selected) { [weak self] in
                        self?.editGroup { $0.bucket = .string(bucket.key) }
                    }
                }
                self.panels.showMenu(ChoiceMenuView(choices: choices), below: row, level: self.menuLevel)
            }
        case .number(let from, let to, let step):
            let row = PanelHStack()
            for (title, text, identifier) in [("От", from, "group-from"), ("До", to, "group-to"), ("Шаг", step, "group-step")] {
                let label = NSTextField(labelWithString: title)
                label.font = PanelMetrics.smallFont
                label.textColor = Palette.textSecondary
                let field = PropertyPopupField(text: text, placeholder: title, identifier: identifier)
                field.onEndEditing = { [weak self] _ in self?.commitNumberBucket() }
                field.onCommand = { [weak self] command in
                    guard command == #selector(NSResponder.insertNewline(_:)) else { return false }
                    self?.commitNumberBucket()
                    return true
                }
                numberFields.append(field)
                row.add(label, .fixed(ceil(label.intrinsicContentSize.width)), height: 16)
                row.add(field, .flexible, height: nil)
            }
            stack.append(row, height: PropertyPopupMetrics.nameBlockHeight)
        case .status(let byGroups):
            let toggle = PanelToggleRow(title: "По группам статуса", isOn: byGroups, identifier: "group-status-groups")
            toggle.onToggle = { [weak self] isOn in self?.editGroup { $0.bucket = isOn ? "group" : nil } }
            stack.append(toggle, height: PropertyPopupMetrics.rowHeight)
        }
        let hideEmpty = PanelToggleRow(title: "Скрывать пустые группы", isOn: model.hideEmpty, identifier: "group-hide-empty")
        hideEmpty.onToggle = { [weak self] isOn in self?.editGroup { $0.hideEmpty = isOn } }
        stack.append(hideEmpty, height: PropertyPopupMetrics.rowHeight)
        separator()
        let order = controller.groupOrder
        let all = PanelLinkButton(title: model.allHidden ? "Показать все" : "Скрыть все", identifier: "group-hide-all")
        all.onPress = { [weak self] in
            let hide = !model.allHidden
            self?.edit { try $0.setAllGroupsHidden(hide, order: order, in: $1) }
        }
        stack.append(PanelCaptionRow("Группы", link: all), height: PropertyPopupMetrics.captionHeight)
        for group in model.groups {
            let eye = PanelIconButton(symbol: group.isHidden ? "eye.slash" : "eye", label: group.isHidden ? "Показать" : "Скрыть",
                                      identifier: "group-eye-\(group.label.title)")
            eye.onPress = { [weak self] in self?.edit { try $0.setGroupHidden(group.key, !group.isHidden, order: order, in: $1) } }
            let label: PanelHandleRow.Label = switch group.label {
            case .option(let name, let color): .chip(name, color)
            case .text(let text): .text(text, icon: nil)
            case .empty(let text): .muted(text)
            }
            let row = PanelHandleRow(label: label, trailing: eye, identifier: "group-row-\(group.label.title)")
            row.onDrag = { [weak self] event in self?.drag(group.key, startingWith: event, model: model, order: order) }
            groupRows.append(row)
            stack.append(row, height: PropertyPopupMetrics.rowHeight)
        }
        separator()
        _ = row("Убрать группировку", icon: "trash", identifier: "group-remove") { [weak self] _ in
            self?.edit { try $0.setGroup(nil, of: $1) }
        }
    }

    override func reload() {
        let model = self.model
        if key(model) != builtKey { return rebuild() }
        if case .number(let from, let to, let step) = model.bucket {
            for (field, text) in zip(numberFields, [from, to, step]) where !field.isFocused { field.field.stringValue = text }
        }
    }

    override func flush() { if numberFields.contains(where: \.isFocused) { commitNumberBucket() } }

    /// Без группировки: «Нет ✓» и свойства, кроме ID и файлов.
    private func buildPropertyList(current: UUID?) {
        stack.append(PropertyPopupCaption("Группировать по"), height: PropertyPopupMetrics.captionHeight)
        for choice in groupChoices(current: current) {
            let row = ChoiceRowView(choice)
            row.onPress = { choice.perform() }
            stack.append(row, height: PropertyPopupMetrics.rowHeight)
        }
    }

    private func groupChoices(current: UUID?) -> [PanelChoice] {
        let none = PanelChoice(title: "Нет", isChecked: current == nil, identifier: "group-by-none") { [weak self] in
            self?.edit { try $0.setGroup(nil, of: $1) }
        }
        return [none] + PropertyChoices.forGroup(controller.catalog).map { property in
            PanelChoice(title: property.name, icon: CellKind.for(property.kind).symbol, isChecked: property.id == current,
                        identifier: "group-by-\(property.name)") { [weak self] in
                self?.edit { try $0.group(by: property.id, in: $1) }
            }
        }
    }

    private func showPropertyMenu(current: UUID, below row: NSView) {
        panels.showMenu(ChoiceMenuView(choices: groupChoices(current: current)), below: row, level: menuLevel)
    }

    private func editGroup(_ change: @escaping (inout GroupSettings) -> Void) {
        let order = controller.groupOrder
        edit { try $0.editGroup(of: $1, order: order) { change(&$0) } }
    }

    private func commitNumberBucket() {
        guard numberFields.count == 3,
              let bucket = GroupingPanelModel.numberBucket(from: numberFields[0].text, to: numberFields[1].text, step: numberFields[2].text) else { return }
        editGroup { $0.bucket = bucket }
    }

    private func drag(_ key: String, startingWith event: NSEvent, model: GroupingPanelModel, order: [String]) {
        guard let insertion = RowDrag.track(rows: groupRows, in: stack, startingWith: event),
              let index = model.moveIndex(of: key, insertion: insertion) else { return }
        edit { try $0.moveGroup(key, to: index, order: order, in: $1) }
    }
}

/// Окно раскладки (`notion-layout-settings.png`): плитка «Таблица», «Переносить весь текст», «Открывать строки ›»,
/// «Предел загрузки ›» (только у встроенной).
@MainActor
final class LayoutPage: PanelPage {
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    init(panels: ViewPanels) {
        super.init(panels: panels, width: PanelMetrics.windowWidth)
        setAccessibilityIdentifier("layout-window")
    }

    override func build() {
        let model = LayoutPanelModel(view: controller.view, isInline: controller.isInline)
        stack.append(LayoutTile(title: "Таблица", symbol: "tablecells"), height: 76)
        let wrap = PanelToggleRow(title: "Переносить весь текст", isOn: model.options.wrapAllContent, identifier: "layout-wrap")
        wrap.onToggle = { [weak self] isOn in self?.edit { try $0.setWrapAllContent(isOn, in: $1) } }
        stack.append(wrap, height: PropertyPopupMetrics.rowHeight)
        _ = row("Открывать строки", icon: nil, value: model.openModeTitle, chevron: true, identifier: "layout-open-rows") { [weak self] row in
            guard let self else { return }
            let choices = LayoutPanelModel.openModes.map { option in
                PanelChoice(title: option.title, caption: option.caption, isChecked: option.mode == model.openMode,
                            identifier: "layout-open-\(option.mode.rawValue)") { [weak self] in
                    self?.edit { try $0.setOpenRowsIn(option.mode, in: $1) }
                }
            }
            self.panels.showMenu(ChoiceMenuView(choices: choices, width: 300), below: row, level: self.menuLevel)
        }
        guard model.showsLoadLimit else { return }
        _ = row("Предел загрузки", icon: nil, value: "\(model.options.loadLimit)", chevron: true, identifier: "layout-load-limit") { [weak self] row in
            guard let self else { return }
            let choices = LayoutPanelModel.loadLimits.map { limit in
                PanelChoice(title: "\(limit)", isChecked: limit == model.options.loadLimit, identifier: "layout-limit-\(limit)") { [weak self] in
                    self?.edit { try $0.setLoadLimit(limit, in: $1) }
                }
            }
            self.panels.showMenu(ChoiceMenuView(choices: choices, width: 160), below: row, level: self.menuLevel)
        }
    }
}

/// Плитка вида в «Раскладке»: значок и название, синяя рамка у выбранного (в 004 — одна «Таблица»).
@MainActor
final class LayoutTile: NSView {
    private let title: String
    private let symbol: String

    init(title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        setAccessibilityValue(1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let tile = NSRect(x: PropertyPopupMetrics.padding - PropertyPopupMetrics.inset, y: 6, width: 88, height: bounds.height - 12)
        let path = NSBezierPath(roundedRect: tile.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        path.lineWidth = 2
        Palette.focusRing.setStroke()
        path.stroke()
        ActionMenuIcon.draw(symbol, color: Palette.focusRing, in: NSRect(x: tile.midX - 10, y: tile.minY + 12, width: 20, height: 20))
        let text = NSAttributedString(string: title, attributes: [.font: PanelMetrics.smallFont, .foregroundColor: Palette.focusRing])
        text.draw(at: NSPoint(x: tile.midX - text.size().width / 2, y: tile.maxY - 24))
    }
}
