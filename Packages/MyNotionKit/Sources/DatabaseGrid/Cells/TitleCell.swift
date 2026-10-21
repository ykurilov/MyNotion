import Foundation
import Databases
import NotesCore

/// «Название»: правка на месте (щелчок строку не открывает — открывает «ОТКРЫТЬ», как в Notion); значение — `Page.title`.
struct TitleCell: GridCellType {
    let kind = PropertyKind.title
    func editingText(_ value: JSONValue?, context: PropertyContext) -> String { value?.string ?? "" }
}
