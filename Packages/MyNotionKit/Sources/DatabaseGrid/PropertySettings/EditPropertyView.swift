import AppKit
import Databases
import NotesCore
import VisualStyle

/// Панель «Изменить свойство» (contracts/database-ui.md, `notion-edit-property-number.png`): «← Изменить свойство ×»,
/// поле имени с иконкой типа, «Тип ›» (список типов одной колонкой на месте панели, как «Сменить тип свойства» Notion),
/// раздел настроек типа (`PropertyTypeSettings` историй), «Дублировать свойство», «Удалить свойство».
/// Один вид на два места: панель справа от таблицы и страница окна «Свойства».
@MainActor
final class EditPropertyView: NSView {
    private enum Screen { case main, types }

    private let commands: PropertyMenuCommands
    private(set) var property: DatabaseProperty
    private var screen = Screen.main
    private let stack = PropertyPopupStack()
    private(set) var nameField: PropertyPopupField?
    private var chooser: PropertyTypeChooserView?
    /// «←» на главном экране (панель закрывается, окно «Свойства» возвращается к списку).
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?
    /// «Удалить свойство»: вопрос задаёт презентер.
    var onDelete: ((DatabaseProperty) -> Void)?
    /// Высота содержимого сменилась.
    var onResize: (() -> Void)?

    init(property: DatabaseProperty, commands: PropertyMenuCommands) {
        self.property = property
        self.commands = commands
        super.init(frame: .zero)
        stack.topPadding = 0
        addSubview(stack)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var contentHeight: CGFloat { stack.contentHeight }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    /// Перечитать свойство после правки; `false` — его больше нет (удалено, в том числе с другого Mac).
    @discardableResult
    func reload() -> Bool {
        guard let fresh = try? DatabaseCatalog.read(commands.databaseId, in: commands.store).propertiesById[property.id] else { return false }
        let changed = fresh.kind != property.kind || fresh.name != property.name || fresh.config != property.config
        property = fresh
        // Поле в фокусе не пересобирается — правка имени не обрывается.
        if changed, screen == .main, nameField?.isFocused != true { rebuild() }
        return true
    }

    private func rebuild() {
        stack.removeAll()
        nameField = nil
        chooser = nil
        switch screen {
        case .main: buildMain()
        case .types: buildTypes()
        }
        needsLayout = true
        onResize?()
    }

    private func header(_ title: String, back: @escaping () -> Void) -> PropertyPopupHeader {
        let header = PropertyPopupHeader(title: title)
        header.onBack = back
        header.onClose = { [weak self] in self?.onClose?() }
        return header
    }

    private func buildMain() {
        stack.append(header("Изменить свойство") { [weak self] in self?.commitName(); self?.onBack?() },
                     height: PropertyPopupMetrics.headerHeight, inset: 0)
        let settings = PropertyTypeSettings.settings(for: property.kind)
        let handled = PropertyMenuCommands.panelSlots.union(settings == nil ? [] : [.typeSettings])
        var lastWasAction = false
        for section in PropertySettingsPanel.sections(for: property.kind, handled: handled) {
            switch section.slot {
            case .name:
                let field = PropertyPopupField(text: property.name, placeholder: "Название свойства", icon: CellKind.for(property.kind).symbol,
                                               identifier: "edit-property-name")
                field.onCommand = { [weak self] command in
                    switch command {
                    case #selector(NSResponder.insertNewline(_:)):
                        self?.commitName()
                        self?.window?.makeFirstResponder(nil)
                        return true
                    case #selector(NSResponder.cancelOperation(_:)):
                        self?.commitName()
                        self?.onClose?()
                        return true
                    default: return false
                    }
                }
                field.onEndEditing = { [weak self] _ in self?.commitName() }
                nameField = field
                stack.append(field, height: PropertyPopupMetrics.nameBlockHeight)
            case .type:
                let row = PropertyPopupRow(title: "Тип", icon: "arrow.triangle.2.circlepath", value: CellKind.for(property.kind).title,
                                           showsChevron: true, identifier: "edit-property-type")
                row.onPress = { [weak self] in self?.show(.types) }
                stack.append(row, height: PropertyPopupMetrics.rowHeight)
            case .typeSettings:
                guard let settings else { continue }
                let view = settings.makeView(PropertyTypeSettingsContext(property: property, store: commands.store,
                                                                         operations: commands.operations, viewId: commands.viewId))
                stack.append(view, height: view.fittingSize.height)
            case .wrapText:
                continue
            case .duplicate, .delete:
                if !lastWasAction { stack.append(PropertyPopupSeparator(), height: PropertyPopupMetrics.separatorHeight) }
                let isDelete = section.slot == .delete
                let row = PropertyPopupRow(title: isDelete ? "Удалить свойство" : "Дублировать свойство", icon: isDelete ? "trash" : "square.on.square",
                                           identifier: isDelete ? "edit-property-delete" : "edit-property-duplicate")
                row.onPress = { [weak self] in
                    guard let self else { return }
                    if isDelete {
                        self.onDelete?(self.property)
                    } else {
                        PropertyMenuPresenter.attempt { _ = try self.commands.perform(.duplicate, on: self.property) }
                    }
                }
                stack.append(row, height: PropertyPopupMetrics.rowHeight)
                lastWasAction = true
                continue
            }
            lastWasAction = false
        }
    }

    private func buildTypes() {
        stack.append(header("Сменить тип свойства") { [weak self] in self?.show(.main) }, height: PropertyPopupMetrics.headerHeight, inset: 0)
        let commands = commands
        let current = property
        let chooser = PropertyTypeChooserView(columns: 1, current: property.kind, caption: "Тип") { query in
            (try? commands.typeRows(current: current, matching: query)) ?? []
        }
        chooser.list.onChoose = { [weak self] kind in
            guard let self else { return }
            PropertyMenuPresenter.attempt { try self.commands.changeType(self.property, to: kind) }
            self.reload()
            self.show(.main)
        }
        chooser.onCancel = { [weak self] in self?.show(.main) }
        chooser.onResize = { [weak self, weak chooser] in
            guard let self, let chooser else { return }
            self.stack.setHeight(chooser.contentHeight, of: chooser)
            self.onResize?()
        }
        self.chooser = chooser
        stack.append(chooser, height: chooser.contentHeight)
    }

    private func show(_ next: Screen) {
        commitName()
        screen = next
        rebuild()
        focusFirstField()
    }

    /// Фокус — в поле имени или поиска типа.
    func focusFirstField() {
        DispatchQueue.main.async { [weak self] in
            if let chooser = self?.chooser { chooser.search.focus() } else { self?.nameField?.focus() }
        }
    }

    private func commitName() {
        guard let field = nameField else { return }
        PropertyMenuPresenter.attempt {
            if try commands.rename(property, to: field.text) { property.name = field.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}
