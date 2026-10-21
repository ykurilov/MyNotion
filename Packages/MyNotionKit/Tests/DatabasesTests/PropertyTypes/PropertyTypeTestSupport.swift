import Foundation
@testable import Databases
@testable import NotesCore

/// Контекст типа для тестов: свойство, варианты, календарь Москвы, язык — русский (показ) и английский (CSV всегда).
enum TypeFixture {
    static let timeZone = TimeZone(identifier: "Europe/Moscow")!
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        return calendar
    }

    static let database = UUID(uuidString: "0193A1B2-0000-7000-8000-0000000000DB")!

    static func property(_ kind: PropertyKind, _ config: JSONValue = .emptyObject, name: String = "Свойство") -> DatabaseProperty {
        DatabaseProperty(id: UUID(uuidString: "0193A1B2-0000-7000-8000-0000000000F1")!, databaseId: database, name: name, kind: kind,
                         config: config, sortKey: .between(nil, nil))
    }

    static func context(_ kind: PropertyKind, _ config: JSONValue = .emptyObject, options: [SelectOption] = [],
                        locale: Locale = Locale(identifier: "ru_RU")) -> PropertyContext {
        PropertyContext(property: property(kind, config), options: options, calendar: calendar, locale: locale)
    }

    /// Варианты «Низкий», «Средний», «Высокий» (порядок 0, 1, 2).
    static let options: [SelectOption] = ["Низкий", "Средний", "Высокий"].enumerated().map { index, name in
        SelectOption(id: UUID(uuidString: "0193A1B2-0000-7000-8000-00000000001\(index)")!, propertyId: property(.select).id, name: name,
                     color: [.gray, .blue, .red][index], sortKey: FractionalSortKey(rawValue: ["a", "b", "c"][index])!)
    }

    static func id(_ option: SelectOption) -> JSONValue { .string(option.id.uuidString.lowercased()) }

    static func text(_ string: String) -> JSONValue { ["runs": [], "string": .string(string)] }

    static func date(_ start: String, end: String? = nil, hasTime: Bool = false) -> JSONValue {
        var value: JSONValue = ["start": .string(start), "hasTime": .bool(hasTime), "timeZone": "Europe/Moscow"]
        if let end { value["end"] = .string(end) }
        return value
    }

    static func seconds(_ text: String) -> Double {
        DateText.parse(text, timeZone: "Europe/Moscow")!.timeIntervalSince1970
    }
}
