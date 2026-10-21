import Foundation
import Databases
import NotesCore

/// Число: правка на месте без формата («1 234,50 ₽» правится как «1234.5»), показ — по формату свойства, вправо.
struct NumberCell: GridCellType {
    let kind = PropertyKind.number
    func editingText(_ value: JSONValue?, context: PropertyContext) -> String {
        guard let number = value?.number else { return "" }
        return number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
    }
}
