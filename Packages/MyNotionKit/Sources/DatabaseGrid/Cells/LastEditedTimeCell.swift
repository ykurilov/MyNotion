import Foundation
import Databases
import NotesCore

/// «Изменено»: дата последней правки строки (её текста и значений), без правки.
struct LastEditedTimeCell: GridCellType {
    let kind = PropertyKind.lastEditedTime
}
