import ControlProtocol
import Foundation

/// Блоки, иконки и обложки — этап 3 005 (US2). Имя команды — слова каталога через «.».
public enum BlockHandlers {
    public static let all: [String: CommandHandler] = [
        "block.kinds": BlockContentCommands.kinds,
        "block.get": BlockContentCommands.get,
        "block.insert": BlockContentCommands.insert,
        "block.update": BlockContentCommands.update,
        "block.table-widths": BlockContentCommands.tableWidths,
        "block.move": BlockLayoutCommands.move,
        "block.indent": BlockLayoutCommands.indent,
        "block.outdent": BlockLayoutCommands.outdent,
        "block.delete": BlockLayoutCommands.delete,
        "block.move-to-page": BlockLayoutCommands.moveToPage,
        "block.check": BlockStateCommands.check,
        "block.uncheck": BlockStateCommands.uncheck,
        "block.expand": BlockStateCommands.expand,
        "block.collapse": BlockStateCommands.collapse,
        "page.icon": PageAppearanceCommands.icon,
        "page.cover": PageAppearanceCommands.cover,
    ]
}
