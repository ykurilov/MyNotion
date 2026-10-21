import AppKit
import Databases
import NotesCore
import VisualStyle

/// Основа окон типа US2 в панели «Изменить свойство»: столбик строк, подменю выбора сбоку от строки и запись настроек
/// свойства одним шагом ⌘Z (`setPropertyConfig`). Настройки читаются из хранилища в момент правки: окно могло жить
/// дольше правки с другого Mac.
@MainActor
class TypeSettingsView: NSView, PropertyTypeSettingsResizing {
    let context: PropertyTypeSettingsContext
    let stack = PropertyPopupStack()
    let submenu = PopupCard()
    var onHeightChange: (() -> Void)?

    init(context: PropertyTypeSettingsContext) {
        self.context = context
        super.init(frame: NSRect(x: 0, y: 0, width: PropertyPopupMetrics.panelWidth, height: 100))
        stack.topPadding = 0
        stack.bottomPadding = 4
        addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { NSSize(width: frame.width, height: stack.contentHeight) }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    var storedConfig: JSONValue {
        ((try? context.store.write { try $0.property(context.property.id)?.config }) ?? nil) ?? context.property.config
    }

    /// Правка настроек свойства; без изменений шага нет.
    func updateConfig(_ edit: (inout JSONValue) -> Void) {
        let stored = storedConfig
        var config = stored
        edit(&config)
        guard config != stored else { return }
        do { try context.operations.setPropertyConfig(context.property.id, config) } catch { NSSound.beep() }
    }

    /// Список выбора сбоку от строки; выбор закрывает его до записи (панель после записи пересобирается).
    func showChoices(_ items: [ChoiceListView.Item], checked: String?, besides row: NSView, width: CGFloat = 220,
                     filterPlaceholder: String? = nil, identifier: String, choose: @escaping (String) -> Void) {
        let list = ChoiceListView(items: items, checked: checked, width: width, filterPlaceholder: filterPlaceholder, identifier: identifier)
        list.onChoose = { [weak self] id in
            self?.submenu.close()
            choose(id)
        }
        submenu.show(list, size: list.preferredSize, besides: row, gap: 0)
        list.focusFirstField()
    }

    func row(_ title: String, icon: String?, detail: String?, identifier: String, press: @escaping (ChoiceRow) -> Void) -> ChoiceRow {
        let row = ChoiceRow(title: title, detail: detail, icon: icon, identifier: identifier)
        row.showsChevron = true
        row.onPress = { [weak row] in if let row { press(row) } }
        stack.append(row, height: PropertyPopupMetrics.rowHeight, inset: 0)
        return row
    }

    func heightDidChange() {
        needsLayout = true
        onHeightChange?()
    }
}

/// Формат даты и времени свойства (`notion-edit-property-date.png`): «Формат даты ›», «Формат времени ›».
@MainActor
final class DateSettingsView: TypeSettingsView {
    nonisolated static let settings = PropertyTypeSettings(kinds: [.date]) { DateSettingsView(context: $0) }

    override init(context: PropertyTypeSettingsContext) {
        super.init(context: context)
        let config = context.property.config
        let date = DateDisplayFormat(rawValue: config["dateFormat"]?.string ?? "") ?? .full
        let time = TimeDisplayFormat(rawValue: config["timeFormat"]?.string ?? "") ?? .h24
        _ = row("Формат даты", icon: "calendar", detail: date.title, identifier: "date-settings-format") { [weak self] row in
            self?.showChoices(DateDisplayFormat.allCases.map { .init(id: $0.rawValue, title: $0.title) }, checked: date.rawValue, besides: row,
                              identifier: "date-settings-format-list") { id in
                self?.updateConfig { $0["dateFormat"] = id == DateDisplayFormat.full.rawValue ? nil : .string(id) }
            }
        }
        _ = row("Формат времени", icon: "clock", detail: time.title, identifier: "date-settings-time") { [weak self] row in
            self?.showChoices(TimeDisplayFormat.allCases.map { .init(id: $0.rawValue, title: $0.title) }, checked: time.rawValue, besides: row,
                              identifier: "date-settings-time-list") { id in
                self?.updateConfig { $0["timeFormat"] = .string(id) }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }
}
