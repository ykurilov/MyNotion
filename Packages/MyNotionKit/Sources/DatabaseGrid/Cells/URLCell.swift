import Foundation
import Databases
import NotesCore

/// Ссылка: правка на месте, при наведении — кнопка «Открыть ссылку»; без схемы — `https://`.
struct URLCell: GridCellType {
    let kind = PropertyKind.url
    func hoverAction(_ value: JSONValue?) -> CellHoverAction? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let full = text.contains("://") || text.hasPrefix("mailto:") ? text : "https://" + text
        return URL(string: full).map { CellHoverAction(symbol: "arrow.up.right", tooltip: "Открыть ссылку", url: $0) }
    }
}
