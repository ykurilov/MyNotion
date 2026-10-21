import AppKit
import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    /// Встроенная база (004, research R1, R4): вид-вложение, сетку даёт фабрика видов приложения (`BlockViewFactories`),
    /// редактор знает только протокол. Без фабрики — пустая рамка высотой заглушки. В меню «/» — две строки вставки, как
    /// «Database - Inline» и «Database - Full page» у Notion 7.39; базу создают операции `Databases` у владельца окна.
    /// Превратить блок в базу нельзя — строки «Превратить в» нет.
    static let database: BlockKindDescriptor = {
        var descriptor = BlockKindDescriptor(kind: .database)
        descriptor.insertMenuItems = [
            PopupMenuItem(title: "База данных — встроенная", icon: .symbol("tablecells"),
                          keywords: ["database", "inline", "база", "встроенная"], action: .insertDatabase(inline: true)),
            PopupMenuItem(title: "База данных — на всю страницу", icon: .symbol("tablecells.fill"),
                          keywords: ["database", "full page", "база", "страница"], action: .insertDatabase(inline: false)),
        ]
        return descriptor
    }()
}
