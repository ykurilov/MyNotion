import Foundation
import Databases
import NotesCore

/// Текст: правка на месте, перевод строки — ⇧Enter.
struct TextCell: GridCellType {
    let kind = PropertyKind.text
}
