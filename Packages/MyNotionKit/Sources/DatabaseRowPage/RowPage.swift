import DatabaseGrid
import Databases
import Foundation
import GRDB
import NotesCore

/// Как правится свойство на странице строки (contracts/database-ui.md, «Страница строки»: «правка как в ячейке»).
public enum RowPropertyEditing: Sendable, Hashable {
    /// Поле на месте: текст, число, ссылка, email, телефон; Enter и Esc — готово.
    case field
    /// Щелчок переключает: флажок.
    case toggle
    /// Окно правки (выбор, статус, дата, файлы, связь — окна US2 и US4); пока только показ.
    case popup
    /// Без правки: ID, создано, изменено, формула, сводка.
    case readOnly
}

/// Строка свойства под названием: слева значок типа и имя серым, справа значение (пустое — «Пусто»).
public struct RowPropertyLine: Sendable, Hashable, Identifiable {
    public static let emptyText = "Пусто"

    public let propertyId: UUID
    public let name: String
    public let kind: PropertyKind
    /// Значок типа (как в шапке колонки).
    public let symbol: String
    public let editing: RowPropertyEditing
    public let presentation: CellPresentation

    public var id: UUID { propertyId }
    public var isEmpty: Bool { presentation == .empty }
}

/// Страница строки базы для чтения: схема базы и значения строки — одним чтением (страница строки открывается редко,
/// свойств у базы десятки).
public struct RowPage: Sendable {
    public let rowId: UUID
    public let catalog: DatabaseCatalog
    public let row: RowSnapshot

    public var databaseId: UUID { catalog.databaseId }

    /// Строка базы (родитель — страница-база) или `nil`: обычная страница, сама база, стёртая страница.
    public static func read(_ rowId: UUID, in db: Database) throws -> RowPage? {
        guard let parent = try String.fetchOne(db, sql: "SELECT parentId FROM page WHERE id = ?", arguments: [rowId.databaseText]),
              let databaseId = UUID(uuidString: parent),
              try Bool.fetchOne(db, sql: "SELECT 1 FROM db_database WHERE pageId = ?", arguments: [databaseId.databaseText]) == true
        else { return nil }
        let catalog = try DatabaseCatalog.read(databaseId, in: db)
        guard let row = try RowWindowReader.read([rowId], catalog: catalog, in: db)[rowId] else { return nil }
        return RowPage(rowId: rowId, catalog: catalog, row: row)
    }

    public static func read(_ rowId: UUID, in store: NotesStore) throws -> RowPage? {
        try store.database.dbWriter.read { try read(rowId, in: $0) }
    }

    /// Свойства под названием по порядку базы (`sortKey`); «Название» — в заголовке страницы, здесь его нет.
    public var lines: [RowPropertyLine] {
        catalog.properties.filter { $0.kind != .title }.map { property in
            let cell = CellKind.for(property.kind)
            return RowPropertyLine(propertyId: property.id, name: property.name, kind: property.kind, symbol: cell.symbol,
                                   editing: Self.editing(cell.editing), presentation: CellPresenter.present(property, in: row, context: catalog.context(for: property)))
        }
    }

    static func editing(_ editing: CellEditing) -> RowPropertyEditing {
        switch editing {
        case .inPlace: .field
        case .toggle: .toggle
        case .popup: .popup
        case .none: .readOnly
        }
    }

    /// Текст значения в поле правки: число — без формата (как его набирают), текст — без оформления.
    public func editText(of propertyId: UUID) -> String {
        guard let property = catalog.propertiesById[propertyId], let value = row.cells[propertyId] else { return "" }
        if property.kind == .number, let number = value.number {
            return number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        }
        return PropertyTypes.type(for: property.kind).csvText(value, in: catalog.context(for: property))
    }

    /// Значение из набранного в поле (`nil` — стереть): разбор, как при вставке из таблицы.
    public func value(fromText text: String, for propertyId: UUID) -> JSONValue? {
        guard let property = catalog.propertiesById[propertyId] else { return nil }
        guard case .value(let value) = PropertyTypes.type(for: property.kind).parseCSV(text, in: catalog.context(for: property)) else { return nil }
        return value
    }

    /// Флажок после щелчка.
    public func toggledValue(of propertyId: UUID) -> JSONValue {
        .bool(!(row.cells[propertyId]?.bool ?? false))
    }
}
