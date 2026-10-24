import ControlProtocol
import Databases
import Foundation
import NotesCore

/// Что нужно кодеку ячеек: свойства и варианты базы, календарь (пояс дат без времени), вложения и названия упоминаний.
public struct CellContext: Sendable {
    public var catalog: DatabaseCatalog
    public var calendar: Calendar
    public var attachments: AttachmentLookup
    public var titles: MentionTitles

    public init(catalog: DatabaseCatalog, calendar: Calendar = .current, attachments: @escaping AttachmentLookup = { _ in nil },
                titles: @escaping MentionTitles = { _ in nil }) {
        self.catalog = catalog
        self.calendar = calendar
        self.attachments = attachments
        self.titles = titles
    }

    func options(of property: DatabaseProperty) -> [SelectOption] {
        (catalog.options[property.id] ?? []).filter { $0.deletedAt == nil }
    }

    /// Вариант по id или имени (без регистра, `ё` = `е`).
    func option(_ text: String, of property: DatabaseProperty) -> SelectOption? {
        let options = options(of: property)
        if let id = UUID(uuidString: text), let option = options.first(where: { $0.id == id }) { return option }
        let key = PagePath.normalized(text)
        return options.first { PagePath.normalized($0.name) == key }
    }
}

/// Что записать в ячейку. Название, связь и новые варианты пишутся не в `db_cell`: их доводит обработчик.
public enum CellInput: Sendable, Hashable {
    /// Значение `db_cell` как хранится.
    case value(JSONValue)
    case clear
    /// Название строки — `Page.title`.
    case title(String)
    /// Id или названия строк связанной базы.
    case relation([String])
    /// Есть варианты без записи в базе: обработчик создаёт их (`warnings: option_created`) и пишет все.
    case newOptions(existing: [UUID], missing: [String])
}

/// Ячейки по имени свойства (contracts/block-json.md, «Ячейки»): варианты — именами, текст — Markdown строки,
/// дата без времени в поясе базы — `"2026-10-24"`.
public enum CellValueJSON {
    static let readOnlyKinds: Set<PropertyKind> = [.rollup, .formula, .createdTime, .lastEditedTime, .uniqueId]

    public static func encode(_ value: JSONValue, of property: DatabaseProperty, in context: CellContext) -> ControlJSON {
        switch property.kind {
        case .text:
            guard let text = try? value.decoded(as: InlineText.self) else { return value.control }
            return .string(InlineMarkdownCodec.markdown(text, titles: context.titles))
        case .select, .status:
            return optionName(value, of: property, in: context)
        case .multiSelect:
            guard let items = value.array else { return value.control }
            return .array(items.map { optionName($0, of: property, in: context) })
        case .date:
            return encodeDate(value, in: context)
        case .files:
            guard let items = value.array else { return value.control }
            return .array(items.map { item in
                if let ref = try? item["attachment"]?.decoded(as: AttachmentRef.self) {
                    return ["attachmentId": .string(ref.id.controlText), "name": .string(ref.name)]
                }
                return item.control
            })
        default:
            return value.control
        }
    }

    private static func optionName(_ value: JSONValue, of property: DatabaseProperty, in context: CellContext) -> ControlJSON {
        guard let id = value.string.flatMap(UUID.init(uuidString:)), let option = context.catalog.optionsById[id] else { return value.control }
        return .string(option.name)
    }

    private static let plainDateKeys: Set<String> = ["start", "hasTime", "timeZone"]

    private static func encodeDate(_ value: JSONValue, in context: CellContext) -> ControlJSON {
        guard let object = value.object, let start = object["start"]?.string else { return value.control }
        if Set(object.keys) == plainDateKeys, object["hasTime"] == .bool(false),
           object["timeZone"]?.string == context.calendar.timeZone.identifier {
            return .string(start)
        }
        var result = object.filter { !["hasTime", "reminder"].contains($0.key) }.mapValues(\.control)
        result["time"] = .bool(object["hasTime"]?.bool ?? false)
        if let reminder = object["reminder"] { result["remind"] = reminder.control }
        return .object(result)
    }

    // MARK: Вход

    public static func decode(_ json: ControlJSON, for property: DatabaseProperty, in context: CellContext) throws(ControlError) -> CellInput {
        let kind = property.kind
        if readOnlyKinds.contains(kind) {
            throw ControlError(.readOnlyProperty, "Свойство «\(property.name)» вычисляется само: записать в него нельзя",
                               hint: "Пишите в свойства, из которых оно считается",
                               details: ["property": .string(property.name), "type": .string(kind.rawValue)])
        }
        if json.isNull { return kind == .title ? .title("") : .clear }
        switch kind {
        case .title:
            guard let text = json.string else { throw invalid(json, property) }
            return .title(text)
        case .text:
            guard let markdown = json.string, let value = try? JSONValue(encoding: InlineMarkdownCodec.inlineText(markdown)) else {
                throw invalid(json, property)
            }
            return .value(value)
        case .number:
            if let number = json.number { return .value(.number(number)) }
            guard let number = json.string.flatMap({ Double($0.replacingOccurrences(of: ",", with: ".")) }) else { throw invalid(json, property) }
            return .value(.number(number))
        case .checkbox:
            guard let flag = json.bool else { throw invalid(json, property) }
            return .value(.bool(flag))
        case .url, .email, .phone:
            guard let text = json.string else { throw invalid(json, property) }
            return .value(.string(text))
        case .select, .status:
            guard let name = json.string else { throw invalid(json, property) }
            if let option = context.option(name, of: property) { return .value(.string(option.id.controlText)) }
            if kind == .status { throw optionNotFound(name, property, in: context) }
            return .newOptions(existing: [], missing: [name])
        case .multiSelect:
            let names = json.string.map { [$0] } ?? json.array?.compactMap(\.string)
            guard let names, names.count == (json.array?.count ?? 1) else { throw invalid(json, property) }
            var existing: [UUID] = [], missing: [String] = []
            for name in names {
                if let option = context.option(name, of: property) {
                    if !existing.contains(option.id) { existing.append(option.id) }
                } else if !missing.contains(name) {
                    missing.append(name)
                }
            }
            return missing.isEmpty ? .value(.array(existing.map { .string($0.controlText) })) : .newOptions(existing: existing, missing: missing)
        case .date:
            return .value(try date(json, property, in: context))
        case .files:
            return .value(try files(json, property, in: context))
        case .relation:
            let items = json.array ?? [json]
            let pointers = items.compactMap { $0.string ?? $0["id"]?.string }
            guard pointers.count == items.count else { throw invalid(json, property) }
            return .relation(pointers)
        default:
            return .value(json.core)
        }
    }

    private static func date(_ json: ControlJSON, _ property: DatabaseProperty, in context: CellContext) throws(ControlError) -> JSONValue {
        let zone = context.calendar.timeZone.identifier
        if let text = json.string {
            guard let start = dayOrMoment(text) else { throw invalid(json, property) }
            var value = DateCellValue(day: start.parts, timeZone: zone)
            if start.hasTime { value.setHasTime(true, now: (start.parts.hour, start.parts.minute)) }
            return value.json
        }
        guard let object = json.object, let startText = object["start"]?.string, let start = dayOrMoment(startText) else {
            throw invalid(json, property)
        }
        let hasTime = object["time"]?.bool ?? object["hasTime"]?.bool ?? start.hasTime
        var result: [String: JSONValue] = ["start": .string(start.parts.text(hasTime: hasTime)), "hasTime": .bool(hasTime),
                                           "timeZone": .string(object["timeZone"]?.string ?? zone)]
        if let endText = object["end"]?.string {
            guard let end = dayOrMoment(endText) else { throw invalid(json, property) }
            result["end"] = .string(end.parts.text(hasTime: hasTime))
        }
        if let remind = (object["remind"] ?? object["reminder"])?.string {
            guard DateReminder(rawValue: remind) != nil else {
                throw ControlError(.invalidValue, "Неизвестное напоминание «\(remind)»", hint: "Варианты: " + DateReminder.allCases.map(\.rawValue).joined(separator: " "),
                                   details: ["property": .string(property.name), "type": "date",
                                             "allowed": .array(DateReminder.allCases.map { .string($0.rawValue) })])
            }
            result["reminder"] = .string(remind)
        }
        for (key, value) in object where !["start", "end", "time", "hasTime", "timeZone", "remind", "reminder"].contains(key) {
            result[key] = value.core
        }
        return .object(result)
    }

    /// `2026-10-24` или `2026-10-24T09:30`.
    private static func dayOrMoment(_ text: String) -> (parts: DateParts, hasTime: Bool)? {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$"#, options: .regularExpression) != nil,
              let parts = DateParts(text: text), (1...12).contains(parts.month), (1...31).contains(parts.day),
              (0...23).contains(parts.hour), (0...59).contains(parts.minute) else { return nil }
        return (parts, text.contains("T"))
    }

    private static func files(_ json: ControlJSON, _ property: DatabaseProperty, in context: CellContext) throws(ControlError) -> JSONValue {
        guard let items = json.array else { throw invalid(json, property) }
        var result: [JSONValue] = []
        for item in items {
            if let text = item.string ?? item["attachmentId"]?.string {
                guard let id = UUID(uuidString: text), let ref = context.attachments(id), let encoded = try? JSONValue(encoding: ref) else {
                    throw ControlError(.attachmentNotFound, "Нет вложения \(text)", hint: "Сначала добавьте файл: mynotion attachment add",
                                       details: ["property": .string(property.name), "attachmentId": .string(text)])
                }
                result.append(["attachment": encoded])
            } else if let url = item["url"]?.string, let parsed = URL(string: url) {
                result.append(["url": .string(url), "name": .string(item["name"]?.string ?? parsed.lastPathComponent)])
            } else {
                throw invalid(json, property)
            }
        }
        return .array(result)
    }

    private static func optionNotFound(_ name: String, _ property: DatabaseProperty, in context: CellContext) -> ControlError {
        let names = context.options(of: property).map(\.name)
        return ControlError(.optionNotFound, "У статуса «\(property.name)» нет варианта «\(name)»",
                            hint: "Варианты: " + names.joined(separator: ", ") + "; новый — mynotion db option add",
                            details: ["property": .string(property.name), "option": .string(name),
                                      "allowed": .array(names.map { .string($0) })])
    }

    static func invalid(_ json: ControlJSON, _ property: DatabaseProperty) -> ControlError {
        let (expected, example) = expectation(of: property.kind)
        return ControlError(.invalidValue, "Свойству «\(property.name)» (\(property.kind.rawValue)) не подходит \(json.encodedText()): нужно \(expected)",
                            hint: "Пример: \(example.encodedText())",
                            details: ["property": .string(property.name), "type": .string(property.kind.rawValue),
                                      "expected": .string(expected), "example": example])
    }

    static func expectation(of kind: PropertyKind) -> (String, ControlJSON) {
        switch kind {
        case .title: ("строка", "Отчёт")
        case .text: ("строка Markdown", "Купить **молоко**")
        case .number: ("число", 42.5)
        case .select, .status: ("имя варианта", "Срочно")
        case .multiSelect: ("массив имён вариантов", ["A", "B"])
        case .date: ("дата ГГГГ-ММ-ДД или объект {start, end, time, remind}", "2026-10-24")
        case .checkbox: ("true или false", true)
        case .url: ("адрес", "https://example.com")
        case .email: ("почта", "name@example.com")
        case .phone: ("телефон", "+7 900 000-00-00")
        case .files: ("массив id вложений или {url, name}", [["url": "https://example.com/f.pdf", "name": "f.pdf"]])
        case .relation: ("массив id или названий строк", ["Строка"])
        default: ("значение", .null)
        }
    }
}
