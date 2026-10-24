import Foundation
import Databases
import NotesCore

/// Email: правка на месте, при наведении — кнопка «Написать письмо».
struct EmailCell: GridCellType {
    let kind = PropertyKind.email
    func hoverAction(_ value: JSONValue?) -> CellHoverAction? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
              let url = URL(string: "mailto:" + (text.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? text)) else { return nil }
        return CellHoverAction(symbol: "envelope", tooltip: "Написать письмо", url: url)
    }
}
