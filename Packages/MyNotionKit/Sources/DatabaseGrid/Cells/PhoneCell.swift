import Foundation
import Databases
import NotesCore

/// Телефон: правка на месте, при наведении — кнопка «Позвонить» (цифры и «+»).
struct PhoneCell: GridCellType {
    let kind = PropertyKind.phone
    func hoverAction(_ value: JSONValue?) -> CellHoverAction? {
        let digits = (value?.string ?? "").filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty, let url = URL(string: "tel:" + digits) else { return nil }
        return CellHoverAction(symbol: "phone", tooltip: "Позвонить", url: url)
    }
}
