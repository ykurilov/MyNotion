import Foundation
import Databases
import NotesCore

/// Сводка в сетке: итог показывается по `CellPresentation` (число, дата, текст, плашки строк у «как есть» по связи),
/// правки нет — настройка в панели «Изменить свойство» (`PropertySettings/RollupSettings.swift`).
struct RollupCell: GridCellType {
    let kind = PropertyKind.rollup
}
