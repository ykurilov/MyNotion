import AppKit
import NotesCore
import VisualStyle

/// Меню колонки (contracts/database-ui.md, `notion-column-header-menu.png`): сверху поле имени с иконкой типа
/// (переименовать), под ним пункты из реестра (`PropertyMenuCommands.entries`) в виде меню действий 002. Фокус в поле
/// имени; ↑↓ ведут подсветку по пунктам, Enter выбирает подсвеченный пункт или сохраняет имя и закрывает меню, Esc —
/// сохраняет имя и закрывает.
@MainActor
final class ColumnMenuView: NSView {
    let propertyId: UUID
    let nameField: PropertyPopupField
    let actions: ActionMenuView
    /// Меню пора закрыть (имя уже сохранено).
    var onDismiss: (() -> Void)?
    /// Сохранить имя из поля.
    var onCommitName: ((String) -> Void)?

    init(property: DatabaseProperty, entries: [PropertyMenu.Entry], perform: @escaping @MainActor (PropertyMenuSlot, NSView) -> Void) {
        propertyId = property.id
        nameField = PropertyPopupField(text: property.name, placeholder: "Название свойства", icon: CellKind.for(property.kind).symbol,
                                       identifier: "column-menu-name")
        actions = ActionMenuView(entries: entries.map { entry in
            guard let slot = entry.slot else { return .separator }
            return .action(ActionMenuAction(title: entry.title, icon: slot.icon, showsChevron: slot.opensWindowBeside,
                                            identifier: "column-menu-\(slot)") { row in perform(slot, row) })
        }, width: PropertyPopupMetrics.columnMenuWidth)
        super.init(frame: .zero)
        addSubview(nameField)
        addSubview(actions)
        nameField.onCommand = { [weak self] command in self?.handle(command) ?? false }
        frame.size = fittingSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        NSSize(width: PropertyPopupMetrics.columnMenuWidth,
               height: Metrics.PopupMenu.verticalPadding + PropertyPopupMetrics.nameBlockHeight + actions.fittingSize.height)
    }

    override func layout() {
        super.layout()
        let inset = PropertyPopupMetrics.inset
        nameField.frame = NSRect(x: inset, y: Metrics.PopupMenu.verticalPadding, width: bounds.width - 2 * inset,
                                 height: PropertyPopupMetrics.nameBlockHeight)
        actions.frame = NSRect(x: 0, y: nameField.frame.maxY, width: bounds.width, height: actions.fittingSize.height)
    }

    private func handle(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveDown(_:)): actions.moveHighlight(by: 1)
        case #selector(NSResponder.moveUp(_:)): actions.moveHighlight(by: -1)
        case #selector(NSResponder.moveRight(_:)):
            // → открывает окно подсвеченного пункта со «›»; без подсветки — курсор в поле.
            guard let row = actions.highlightedRow, row.action.showsChevron else { return false }
            row.press()
        case #selector(NSResponder.insertNewline(_:)):
            if !actions.pressHighlighted() {
                onCommitName?(nameField.text)
                onDismiss?()
            }
        case #selector(NSResponder.cancelOperation(_:)):
            onCommitName?(nameField.text)
            onDismiss?()
        default: return false
        }
        return true
    }
}

extension PropertyMenuSlot {
    /// Значок пункта (SF Symbols) — близкий к значку Notion 7.39 (`notion-column-header-menu.png`).
    var icon: String {
        switch self {
        case .editProperty: "slider.horizontal.3"
        case .changeType: "arrow.triangle.2.circlepath"
        case .filter: "line.3.horizontal.decrease"
        case .sort: "arrow.up.arrow.down"
        case .group: "rectangle.grid.1x2"
        case .calculate: "sum"
        case .hide: "eye.slash"
        case .wrap: "arrow.right.to.line.compact"
        case .insertLeft: "arrow.left.to.line"
        case .insertRight: "arrow.right.to.line"
        case .duplicate: "square.on.square"
        case .delete: "trash"
        }
    }

    /// «›» справа: пункт открывает окно рядом (панель «Изменить свойство», список типов).
    var opensWindowBeside: Bool { self == .editProperty || self == .changeType }
}
