import Foundation
import Databases
import NotesCore

/// Флажок: щелчок переключает, правки на месте нет.
struct CheckboxCell: GridCellType {
    let kind = PropertyKind.checkbox
    func editingText(_ value: JSONValue?, context: PropertyContext) -> String { "" }
}
