import Foundation
import Databases
import NotesCore

/// «Создано»: дата создания строки, без правки.
struct CreatedTimeCell: GridCellType {
    let kind = PropertyKind.createdTime
}
