import Foundation
import Databases
import NotesCore

/// ID: номер строки, вправо, без правки.
struct UniqueIdCell: GridCellType {
    let kind = PropertyKind.uniqueId
}
