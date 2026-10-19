import AppKit
import NotesCore

/// Меню строки и столбца (contracts/blocks-and-keys.md, «Таблица»): вставить выше, ниже, слева, справа; удалить;
/// строка и столбец заголовков.
@MainActor
enum TableMenus {
    static func menu(for cell: TableCellPosition, in grid: TableGrid, table: TableView) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: TableAction, checked: Bool = false) {
            let item = NSMenuItem(title: title, action: #selector(TableMenuTarget.choose(_:)), keyEquivalent: "")
            let target = TableMenuTarget(table: table, action: action, cell: cell)
            item.target = target
            item.representedObject = target
            item.state = checked ? .on : .off
            menu.addItem(item)
        }
        add("Вставить строку выше", .insertRowAbove)
        add("Вставить строку ниже", .insertRowBelow)
        add("Вставить столбец слева", .insertColumnLeft)
        add("Вставить столбец справа", .insertColumnRight)
        menu.addItem(.separator())
        add("Удалить строку", .deleteRow)
        add("Удалить столбец", .deleteColumn)
        menu.addItem(.separator())
        add("Строка заголовков", .toggleHeaderRow, checked: grid.hasHeaderRow)
        add("Столбец заголовков", .toggleHeaderColumn, checked: grid.hasHeaderColumn)
        return menu
    }
}

/// Цель пункта меню: таблица, действие и ячейка, у которой открыли меню.
@MainActor
final class TableMenuTarget: NSObject {
    weak var table: TableView?
    let action: TableAction
    let cell: TableCellPosition

    init(table: TableView, action: TableAction, cell: TableCellPosition) {
        self.table = table
        self.action = action
        self.cell = cell
    }

    @objc func choose(_ sender: Any?) {
        table?.perform(action, at: cell)
    }
}
