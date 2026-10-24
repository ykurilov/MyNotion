import AppKit
import Databases
import NotesCore
import VisualStyle

/// Действия меню строки, которые даёт окно приложения (избранное, иконка, новое окно, перенос). Пункт без действия
/// не показывается (реестр `RowMenuItem`).
@MainActor
public struct RowMenuActions {
    public var isFavorite: ((UUID) -> Bool)?
    public var toggleFavorite: ((UUID) -> Void)?
    public var changeIcon: ((UUID, NSView) -> Void)?
    public var openInNewWindow: ((UUID) -> Void)?
    public var moveTo: ((UUID) -> Void)?

    public init() {}
}

/// Меню строки (правый щелчок, «⠿»; contracts/database-ui.md, «Строки», `notion-row-context-menu.png`): поле
/// «Найти действие…», В избранное, Изменить иконку, Изменить свойство ›, Открыть в ›, Дублировать ⌘D, Переместить в ⇧⌘P,
/// Удалить в корзину ⌫, внизу серым «Изменено …». Карточка и строки — меню действий 002 (`ActionMenuView`).
@MainActor
public final class RowMenuPresenter {
    private let card = PopupCard()
    private let submenuCard = PopupCard()
    private var menu: ActionMenuView?

    public init() {
        card.onClose = { [weak self] in self?.submenuCard.close() }
    }

    public var isShown: Bool { card.isShown }

    /// Меню строк `rows` (выбранные флажками или одна) сетки `grid` у точки `point` (в её координатах).
    public func show(rows: [Int], of grid: DatabaseGridView, at point: NSPoint, actions: RowMenuActions) {
        guard let controller = grid.controller, let first = rows.first, let rowId = controller.content.rowId(at: first) else { return }
        let entries = Self.entries(rowId: rowId, rows: rows, grid: grid, controller: controller, actions: actions, submenu: { [weak self] items, row in
            self?.showSubmenu(items, besides: row)
        })
        let view = ActionMenuView(entries: entries, width: Metrics.PageMenu.width)
        view.onChoose = { [weak self] in self?.close() }
        view.onFilter = { [weak self] in self?.submenuCard.close() }
        menu = view
        card.show(view, size: view.fittingSize, from: point, in: grid)
        view.focusSearch()
    }

    public func close() {
        submenuCard.close()
        card.close()
    }

    private func showSubmenu(_ entries: [ActionMenuEntry], besides row: NSView) {
        let view = ActionMenuView(entries: entries, width: Metrics.PageMenu.width)
        view.onChoose = { [weak self] in self?.close() }
        submenuCard.show(view, size: view.fittingSize, besides: row, gap: 0, preferringRight: true)
    }

    /// Строки меню по реестру `RowMenuItem`: только места с действием.
    static func entries(rowId: UUID, rows: [Int], grid: DatabaseGridView, controller: DatabaseTableController, actions: RowMenuActions,
                        submenu: @escaping @MainActor ([ActionMenuEntry], NSView) -> Void) -> [ActionMenuEntry] {
        var entries: [ActionMenuEntry] = []
        let single = rows.count == 1
        for item in RowMenuItem.ordered(RowMenuItem.all) {
            let identifier = "database-row-menu-\(item.slot)"
            switch item.slot {
            case .findAction:
                entries.append(.search(placeholder: item.title, identifier: "database-row-menu-search"))
            case .favorite:
                guard single, let toggle = actions.toggleFavorite else { continue }
                let title = actions.isFavorite?(rowId) == true ? "Убрать из избранного" : item.title
                entries.append(.action(ActionMenuAction(title: title, icon: "star", identifier: identifier) { _ in toggle(rowId) }))
            case .changeIcon:
                guard single, let change = actions.changeIcon else { continue }
                entries.append(.action(ActionMenuAction(title: item.title, icon: "face.smiling", identifier: identifier) { row in change(rowId, row) }))
            case .editProperty:
                guard single else { continue }
                let editable = controller.content.columns.enumerated().filter { CellKind.for($0.element.property.kind).editing != .none }
                guard !editable.isEmpty else { continue }
                let row = rows[0]
                let items: [ActionMenuEntry] = editable.map { index, column in
                    .action(ActionMenuAction(title: column.property.name, icon: CellKind.for(column.property.kind).symbol) { _ in
                        grid.select(CellPosition(row: row, column: index))
                        grid.beginEditing()
                    })
                }
                entries.append(.action(ActionMenuAction(title: item.title, icon: "pencil", opensSubmenu: true, identifier: identifier) { view in
                    submenu(items, view)
                }))
            case .openIn:
                guard single else { continue }
                let row = rows[0]
                var items: [ActionMenuEntry] = [
                    .action(ActionMenuAction(title: "Новой вкладке", icon: "plus.square.on.square", hint: "⇧⌘↩") { _ in
                        controller.openRow(row, inNewTab: true)
                    }),
                ]
                if let openInNewWindow = actions.openInNewWindow {
                    items.append(.action(ActionMenuAction(title: "Новом окне", icon: "macwindow") { _ in openInNewWindow(rowId) }))
                }
                items.append(.action(ActionMenuAction(title: "Сбоку", icon: "rectangle.righthalf.inset.filled", hint: "⌥-щелчок") { _ in
                    controller.openRow(row, mode: .sidePeek)
                }))
                entries.append(.separator)
                entries.append(.action(ActionMenuAction(title: item.title, icon: "arrow.up.right.square", opensSubmenu: true, identifier: identifier) { view in
                    submenu(items, view)
                }))
            case .duplicate:
                entries.append(.separator)
                entries.append(.action(ActionMenuAction(title: item.title, icon: "plus.square.on.square", hint: item.hint, identifier: identifier) { _ in
                    controller.duplicateRows(rows)
                }))
            case .moveTo:
                guard single, let move = actions.moveTo else { continue }
                entries.append(.action(ActionMenuAction(title: item.title, icon: "arrow.turn.up.right", hint: item.hint, identifier: identifier) { _ in
                    move(rowId)
                }))
            case .trash:
                entries.append(.action(ActionMenuAction(title: item.title, icon: "trash", hint: item.hint, identifier: identifier) { _ in
                    controller.trashRows(rows)
                    grid.clearSelection()
                }))
            case .footer:
                guard single, let page = try? controller.store.write({ try $0.page(rowId) }) else { continue }
                entries.append(.separator)
                entries.append(.footer("Изменено \(Self.editedText(page.updatedAt))", identifier: "database-row-menu-footer"))
            }
        }
        return entries
    }

    static func editedText(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
