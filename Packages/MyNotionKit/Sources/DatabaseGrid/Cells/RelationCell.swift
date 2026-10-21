import Foundation
import Databases
import NotesCore

/// Связь в сетке: названия строк цели плашками (`CellPresentation.chips`); правка — окно связи под ячейкой.
struct RelationCell: GridCellType {
    let kind = PropertyKind.relation
}
