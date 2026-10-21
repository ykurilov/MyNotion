import Foundation
import NotesCore

/// Сравнимые колонки значения (data-model.md, `sortText`, `sortNumber`, `searchText`): по ним запрос вида фильтрует,
/// сортирует и ищет, не разбирая JSON (research R3).
public struct CellComparables: Sendable, Hashable {
    public var sortText: String?
    public var sortNumber: Double?
    public var searchText: String?

    public init(sortText: String? = nil, sortNumber: Double? = nil, searchText: String? = nil) {
        self.sortText = sortText
        self.sortNumber = sortNumber
        self.searchText = searchText
    }
}

/// Значение из CSV: готовое значение или названия вариантов, которых ещё нет (их создаёт операция импорта).
public enum CSVValue: Sendable, Hashable {
    case value(JSONValue?)
    case options([String])
}

/// Всё, что тип знает о свойстве: настройки, варианты по порядку, календарь и язык macOS.
public struct PropertyContext: Sendable {
    public var property: DatabaseProperty
    /// Неудалённые варианты по порядку (у статуса — по группам).
    public let options: [SelectOption]
    public var calendar: Calendar
    public var locale: Locale
    private let optionIndex: [UUID: Int]

    public init(property: DatabaseProperty, options: [SelectOption] = [], calendar: Calendar = .current, locale: Locale = .current) {
        self.property = property
        self.options = options.sorted(by: DatabaseCatalog.optionOrder)
        self.calendar = calendar
        self.locale = locale
        optionIndex = Dictionary(self.options.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public var config: JSONValue { property.config }

    /// Вариант по id из значения и его место.
    public func option(_ value: JSONValue?) -> (option: SelectOption, position: Int)? {
        guard let id = value?.string.flatMap(UUID.init(uuidString:)), let index = optionIndex[id] else { return nil }
        return (options[index], index)
    }

    /// Вариант по названию (без учёта регистра).
    public func option(named name: String) -> SelectOption? {
        let key = SortableText.make(name)
        return options.first { SortableText.make($0.name) == key }
    }
}

extension DatabaseCatalog {
    /// Контекст типа для свойства этой базы.
    public func context(for property: DatabaseProperty, calendar: Calendar = .current, locale: Locale = .current) -> PropertyContext {
        PropertyContext(property: property, options: options[property.id] ?? [], calendar: calendar, locale: locale)
    }
}

/// Модель значения типа свойства (research R5, contracts/property-types.md): без вида. Значение — JSON как в `db_cell`
/// (data-model.md); у типов без ячейки — то, что даёт строка: название — текст, создано и изменено — дата
/// (`PropertyValue.pageDate`), связь — `[{id, title, path?}]`, сводка и формула — итог из `db_computed`.
public protocol PropertyType: Sendable {
    var kind: PropertyKind { get }
    func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables
    /// Текст показа на языке macOS («Пусто» показывает вид).
    func displayText(_ value: JSONValue?, in context: PropertyContext) -> String
    /// Текст в CSV — как у Notion (contracts/sync-v4-and-export.md).
    func csvText(_ value: JSONValue?, in context: PropertyContext) -> String
    func parseCSV(_ text: String, in context: PropertyContext) -> CSVValue
    /// Условия фильтра по порядку меню Notion.
    var filterOperators: [FilterOperator] { get }
    /// Ключи групп строки (`bucket` — шаг группировки дат и чисел); пусто — группа «Нет …».
    func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: JSONValue?) -> [String]
    var isGroupable: Bool { get }
    /// Правка в ячейке (у вычисленных и времени страницы — нет).
    var isEditable: Bool { get }
    /// Вычисления итога колонки (и сводки).
    var calculations: [Calculation] { get }
}

extension PropertyType {
    public var isGroupable: Bool { true }
    public var isEditable: Bool { true }
    public var calculations: [Calculation] { Calculation.common }
}

/// Реестр типов: файл на тип (research R5). Неизвестный тип (от новой версии) ведёт себя как текст без правки.
public enum PropertyTypes {
    public static let all: [any PropertyType] = [
        TitleType(), TextType(), NumberType(), SelectType(), MultiSelectType(), StatusType(), DateType(), CheckboxType(),
        PlainTextType(kind: .url), PlainTextType(kind: .email), PlainTextType(kind: .phone), FilesType(),
        PageTimeType(kind: .createdTime), PageTimeType(kind: .lastEditedTime), RelationType(), RollupType(),
        ComputedType(kind: .formula), UniqueIdType(),
    ]

    private static let byKind: [PropertyKind: any PropertyType] = Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })

    public static func type(for kind: PropertyKind) -> any PropertyType {
        byKind[kind] ?? ComputedType(kind: kind)
    }
}

/// Общие условия текста (contracts/property-types.md, «Условия фильтра»).
extension FilterOperator {
    static let textOperators: [FilterOperator] = [.is, .isNot, .contains, .doesNotContain, .startsWith, .endsWith, .isEmpty, .isNotEmpty]
    static let numberOperators: [FilterOperator] = [.equals, .notEquals, .greaterThan, .lessThan, .greaterThanOrEqual, .lessThanOrEqual,
                                                    .isEmpty, .isNotEmpty]
    static let dateOperators: [FilterOperator] = [.is, .isBefore, .isAfter, .isOnOrBefore, .isOnOrAfter, .isBetween, .isRelativeToToday,
                                                  .isEmpty, .isNotEmpty]
}

/// Значения строк для типов без ячейки.
public enum PropertyValue {
    /// Создано / изменено: дата-время страницы в поясе контекста, с секундами.
    public static func pageDate(_ date: Date, in context: PropertyContext) -> JSONValue {
        let c = context.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let start = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        return ["start": .string(start), "hasTime": true, "timeZone": .string(context.calendar.timeZone.identifier)]
    }
}
