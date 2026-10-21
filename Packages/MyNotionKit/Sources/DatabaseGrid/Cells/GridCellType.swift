import Foundation
import Databases
import NotesCore

/// Кнопка ячейки при наведении: ссылка — открыть, email — письмо, телефон — позвонить (как у Notion 7.39).
public struct CellHoverAction: Sendable, Hashable {
    public let symbol: String
    public let tooltip: String
    public let url: URL
}

/// Поведение ячейки типа в сетке (research R5): текст правки на месте и кнопка при наведении. Рисует сетка по
/// `CellPresentation`; окна правки выбора, даты, файлов, связи — у историй, которые вводят эти типы.
public protocol GridCellType: Sendable {
    var kind: PropertyKind { get }
    /// Текст в поле правки на месте (числа — без формата, как их удобно править).
    func editingText(_ value: JSONValue?, context: PropertyContext) -> String
    /// Кнопка при наведении; `nil` — нет.
    func hoverAction(_ value: JSONValue?) -> CellHoverAction?
}

extension GridCellType {
    public func editingText(_ value: JSONValue?, context: PropertyContext) -> String {
        PropertyTypes.type(for: kind).displayText(value, in: context)
    }
    public func hoverAction(_ value: JSONValue?) -> CellHoverAction? { nil }
}

/// Типы ячеек по типу свойства; тип без своего файла — показ без правки на месте.
public enum GridCellTypes {
    static let all: [any GridCellType] = [
        TitleCell(), TextCell(), NumberCell(), CheckboxCell(), URLCell(), EmailCell(), PhoneCell(), CreatedTimeCell(),
        LastEditedTimeCell(), UniqueIdCell(),
    ]
    private static let byKind: [PropertyKind: any GridCellType] = Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })

    public static func type(for kind: PropertyKind) -> any GridCellType { byKind[kind] ?? PlainCell(kind: kind) }
}

/// Тип без своего поведения в сетке.
struct PlainCell: GridCellType {
    let kind: PropertyKind
}
