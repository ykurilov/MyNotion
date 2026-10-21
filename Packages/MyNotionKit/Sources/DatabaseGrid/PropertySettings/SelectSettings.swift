import AppKit
import Databases
import NotesCore
import VisualStyle

/// Настройки выбора и множественного выбора (`notion-edit-property-select.png`, `notion-select-sort-menu.png`):
/// «Сортировка ›» (Вручную, По алфавиту, В обратном порядке), «Варианты», «+ Добавить вариант» (поле на месте строки,
/// Enter — создать), варианты с ручкой и «›» — меню варианта (имя, удалить, цвет). Варианты перечитываются после
/// правок здесь, в окне ячейки и с другого Mac.
@MainActor
final class SelectSettingsView: OptionSettingsView {
    nonisolated static let settings = PropertyTypeSettings(kinds: [.select, .multiSelect]) { SelectSettingsView(context: $0) }

    override init(context: PropertyTypeSettingsContext) {
        super.init(context: context)
        let sort = OptionSort(rawValue: context.property.config["optionSort"]?.string ?? "") ?? .manual
        _ = row("Сортировка", icon: "arrow.up.arrow.down", detail: sort.title, identifier: "select-sort") { [weak self] row in
            self?.showChoices(OptionSort.allCases.map { .init(id: $0.rawValue, title: $0.title) }, checked: sort.rawValue, besides: row,
                              identifier: "select-sort-list") { id in
                guard let self, let sort = OptionSort(rawValue: id) else { return }
                do { try self.context.operations.setOptionSort(self.context.property.id, to: sort) } catch { NSSound.beep() }
            }
        }
        stack.append(PropertyPopupCaption("Варианты"), height: PropertyPopupMetrics.captionHeight, inset: 0)
        let add = ChoiceRow(title: "Добавить вариант", icon: "plus", identifier: "select-add-option")
        add.onPress = { [weak self] in self?.beginAdding(in: nil) }
        stack.append(add, height: PropertyPopupMetrics.rowHeight, inset: 0)
        appendOptionList()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func sections(_ options: [SelectOption]) -> [OptionListView.Section] {
        [OptionListView.Section(group: nil, title: nil, options: options)]
    }
}

/// Настройки статуса (`notion-edit-property-status.png`): группы «К выполнению», «В работе», «Завершено» с «+»,
/// варианты с ручкой (перетаскивание — и между группами) и «›» — меню варианта.
@MainActor
final class StatusSettingsView: OptionSettingsView {
    nonisolated static let settings = PropertyTypeSettings(kinds: [.status]) { StatusSettingsView(context: $0) }

    override init(context: PropertyTypeSettingsContext) {
        super.init(context: context)
        appendOptionList()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isStatus: Bool { true }

    override func sections(_ options: [SelectOption]) -> [OptionListView.Section] {
        StatusGroup.allCases.map { group in
            OptionListView.Section(group: group, title: group.title, options: options.filter { ($0.statusGroup ?? .todo) == group }, addable: true)
        }
    }
}

/// Общее у настроек выбора и статуса: список вариантов, поле нового варианта и меню варианта.
@MainActor
class OptionSettingsView: TypeSettingsView {
    private var list: OptionListView?
    private var newField: PropertyPopupField?
    private var addingGroup: StatusGroup?
    private let menuCard = PopupCard()
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    var isStatus: Bool { false }

    override init(context: PropertyTypeSettingsContext) {
        super.init(context: context)
        observer = NotificationCenter.default.addObserver(forName: DatabaseOperations.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadOptions() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    func sections(_ options: [SelectOption]) -> [OptionListView.Section] { [] }

    func appendOptionList() {
        let list = OptionListView(style: .settings, isStatus: isStatus)
        list.onMenu = { [weak self] option, row in self?.showMenu(for: option, besides: row) }
        list.onMove = { [weak self] option, after, group in
            guard let self else { return }
            do { try self.context.operations.moveOption(option.id, after: after, group: group) } catch { NSSound.beep() }
        }
        list.onAdd = { [weak self] group in self?.beginAdding(in: group) }
        self.list = list
        stack.append(list, height: 0, inset: 0)
        let field = PropertyPopupField(text: "", placeholder: "Название варианта", identifier: "option-new-name")
        field.isHidden = true
        field.onCommand = { [weak self, weak field] selector in
            guard let self, let field else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                self.createOption(named: field.text)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                self.endAdding()
                return true
            default:
                return false
            }
        }
        newField = field
        stack.append(field, height: 0, inset: 0)
        reloadOptions()
    }

    /// Варианты из хранилища, в порядке списка окна ячейки (`optionSort`).
    func reloadOptions() {
        guard let list else { return }
        let catalog = try? DatabaseCatalog.read(context.property.databaseId, in: context.store)
        guard let property = catalog?.propertiesById[context.property.id], let catalog else { return }
        let options = OptionList.shown(in: catalog.context(for: property))
        list.setSections(sections(options))
        stack.setHeight(list.contentHeight, of: list)
        heightDidChange()
    }

    /// «+ Добавить вариант» / «+» у группы: поле под списком, фокус в нём.
    func beginAdding(in group: StatusGroup?) {
        guard let newField else { return }
        addingGroup = group
        newField.field.placeholderString = group.map { "Новый вариант в «\($0.title)»" } ?? "Название варианта"
        newField.isHidden = false
        stack.setHeight(PropertyPopupMetrics.nameBlockHeight, of: newField)
        heightDidChange()
        newField.focus()
    }

    private func endAdding() {
        guard let newField else { return }
        newField.field.stringValue = ""
        newField.isHidden = true
        stack.setHeight(0, of: newField)
        heightDidChange()
    }

    private func createOption(named name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return endAdding() }
        do {
            _ = try context.operations.createOption(in: context.property.id, named: name, group: addingGroup)
        } catch {
            NSSound.beep()
        }
        // Поле остаётся для следующего варианта, как у Notion.
        newField?.field.stringValue = ""
        newField?.focus()
    }

    private func showMenu(for option: SelectOption, besides row: NSView) {
        let menu = OptionMenuView(option: option)
        let operations = context.operations
        menu.onRename = { name in do { try operations.renameOption(option.id, to: name) } catch { NSSound.beep() } }
        menu.onColor = { color in do { try operations.setOptionColor(option.id, to: color) } catch { NSSound.beep() } }
        menu.onDelete = { [weak self] in
            self?.menuCard.close()
            do { try operations.deleteOption(option.id) } catch { NSSound.beep() }
        }
        menuCard.show(menu, size: menu.preferredSize, besides: row, gap: 0)
        menu.nameField.focus()
    }
}
