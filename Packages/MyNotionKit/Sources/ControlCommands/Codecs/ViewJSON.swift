import ControlProtocol
import Databases
import Foundation
import NotesCore

/// Фильтр, сортировка и группировка вида (contracts/block-json.md, «Вид»): JSON 004, но свойство — именем или id, вариант — именем.
/// В ответе — и имя (`property`), и id (`propertyId`).
public enum ViewJSON {
    // MARK: Фильтр

    public static func encode(_ filter: FilterNode, in catalog: DatabaseCatalog) -> ControlJSON {
        switch filter {
        case .and(let items): ["and": .array(items.map { encode($0, in: catalog) })]
        case .or(let items): ["or": .array(items.map { encode($0, in: catalog) })]
        case .condition(let condition):
            [
                "property": catalog.propertiesById[condition.propertyId].map { .string($0.name) } ?? .null,
                "propertyId": .string(condition.propertyId.controlText), "operator": .string(condition.op.rawValue),
                "value": encodeValue(condition, in: catalog),
            ]
        }
    }

    private static func encodeValue(_ condition: FilterCondition, in catalog: DatabaseCatalog) -> ControlJSON {
        guard let property = catalog.propertiesById[condition.propertyId], usesOptions(property, condition.op) else {
            return condition.value.control
        }
        func name(_ value: JSONValue) -> ControlJSON {
            value.string.flatMap(UUID.init(uuidString:)).flatMap { catalog.optionsById[$0] }.map { .string($0.name) } ?? value.control
        }
        if let items = condition.value.array { return .array(items.map(name)) }
        return name(condition.value)
    }

    /// `null` — без фильтра.
    public static func filter(_ json: ControlJSON, in catalog: DatabaseCatalog) throws(ControlError) -> FilterNode? {
        if json.isNull { return nil }
        return try node(json, in: catalog)
    }

    private static func node(_ json: ControlJSON, in catalog: DatabaseCatalog) throws(ControlError) -> FilterNode {
        if let items = json["and"]?.array { return .and(try nodes(items, in: catalog)) }
        if let items = json["or"]?.array { return .or(try nodes(items, in: catalog)) }
        guard json.object != nil else {
            throw ControlError(.invalidValue, "Условие фильтра — объект {property, operator, value} или {and: […]}/{or: […]}",
                               hint: #"Пример: {"property":"Статус","operator":"isNot","value":"Готово"}"#, details: ["argument": "filter"])
        }
        let property = try self.property(json, in: catalog)
        let allowed = PropertyTypes.type(for: property.kind).filterOperators
        guard let name = json["operator"]?.string, allowed.contains(FilterOperator(rawValue: name)) else {
            throw ControlError(.invalidValue,
                               "Условие «\(json["operator"]?.string ?? "")» не подходит свойству «\(property.name)» (\(property.kind.rawValue))",
                               hint: "Подходят: " + allowed.map(\.rawValue).joined(separator: ", "),
                               details: ["property": .string(property.name), "type": .string(property.kind.rawValue),
                                         "allowed": .array(allowed.map { .string($0.rawValue) })])
        }
        let op = FilterOperator(rawValue: name)
        let value = json["value"] ?? .null
        return .condition(FilterCondition(propertyId: property.id, op: op,
                                          value: usesOptions(property, op) ? try optionIds(value, of: property, in: catalog) : value.core))
    }

    private static func nodes(_ items: [ControlJSON], in catalog: DatabaseCatalog) throws(ControlError) -> [FilterNode] {
        var result: [FilterNode] = []
        for item in items { result.append(try node(item, in: catalog)) }
        return result
    }

    /// Значение условия — вариант (по имени в JSON команд, по id в хранении).
    private static func usesOptions(_ property: DatabaseProperty, _ op: FilterOperator) -> Bool {
        [.select, .multiSelect, .status].contains(property.kind) && [.is, .isNot, .contains, .doesNotContain].contains(op)
    }

    private static func optionIds(_ value: ControlJSON, of property: DatabaseProperty, in catalog: DatabaseCatalog) throws(ControlError) -> JSONValue {
        let options = (catalog.options[property.id] ?? []).filter { $0.deletedAt == nil }
        func id(_ item: ControlJSON) throws(ControlError) -> JSONValue {
            guard let text = item.string else { return item.core }
            if let id = UUID(uuidString: text), options.contains(where: { $0.id == id }) { return .string(id.controlText) }
            let key = PagePath.normalized(text)
            guard let option = options.first(where: { PagePath.normalized($0.name) == key }) else {
                throw ControlError(.optionNotFound, "У свойства «\(property.name)» нет варианта «\(text)»",
                                   hint: "Варианты: " + options.map(\.name).joined(separator: ", "),
                                   details: ["property": .string(property.name), "option": .string(text),
                                             "allowed": .array(options.map { .string($0.name) })])
            }
            return .string(option.id.controlText)
        }
        guard let items = value.array else { return try id(value) }
        var result: [JSONValue] = []
        for item in items { result.append(try id(item)) }
        return .array(result)
    }

    // MARK: Сортировка

    public static func encode(_ sorts: [SortSpec], in catalog: DatabaseCatalog) -> ControlJSON {
        .array(sorts.map { sort in
            ["property": catalog.propertiesById[sort.propertyId].map { .string($0.name) } ?? .null,
             "propertyId": .string(sort.propertyId.controlText), "direction": sort.ascending ? "ascending" : "descending"]
        })
    }

    public static func sorts(_ json: ControlJSON, in catalog: DatabaseCatalog) throws(ControlError) -> [SortSpec] {
        if json.isNull { return [] }
        guard let items = json.array else {
            throw ControlError(.invalidValue, "Сортировка — массив [{property, direction}]",
                               hint: #"Пример: [{"property":"Срок","direction":"ascending"}]"#, details: ["argument": "sort"])
        }
        var result: [SortSpec] = []
        for item in items {
            let property = try self.property(item, in: catalog)
            let direction = item["direction"]?.string ?? "ascending"
            guard direction == "ascending" || direction == "descending" else {
                throw ControlError(.invalidValue, "Направление сортировки — ascending или descending",
                                   details: ["argument": "direction", "allowed": ["ascending", "descending"]])
            }
            result.append(SortSpec(propertyId: property.id, ascending: direction == "ascending"))
        }
        return result
    }

    // MARK: Группировка

    public static func encode(_ group: GroupSettings, in catalog: DatabaseCatalog) -> ControlJSON {
        var object = group.json.control.object ?? [:]
        object["sort"] = object.removeValue(forKey: "groupSort")
        object["property"] = catalog.propertiesById[group.propertyId].map { .string($0.name) } ?? .null
        return .object(object)
    }

    /// `null` — без группировки.
    public static func group(_ json: ControlJSON, in catalog: DatabaseCatalog) throws(ControlError) -> GroupSettings? {
        if json.isNull { return nil }
        guard var object = json.object else {
            throw ControlError(.invalidValue, "Группировка — объект {property, sort, hideEmpty}",
                               hint: #"Пример: {"property":"Статус","sort":"manual","hideEmpty":true}"#, details: ["argument": "group"])
        }
        let property = try self.property(json, in: catalog)
        if let sort = object.removeValue(forKey: "sort") {
            guard let name = sort.string, GroupSort(rawValue: name) != nil else {
                throw ControlError(.invalidValue, "Порядок групп — manual, alphabetical или reverseAlphabetical",
                                   details: ["argument": "sort", "allowed": .array(GroupSort.allCases.map { .string($0.rawValue) })])
            }
            object["groupSort"] = sort
        }
        object.removeValue(forKey: "property")
        object["propertyId"] = .string(property.id.controlText)
        return GroupSettings(json: ControlJSON.object(object).core)
    }

    // MARK: Свойство

    /// Свойство условия по `propertyId` или `property` (id или имя без регистра, `ё` = `е`).
    static func property(_ json: ControlJSON, in catalog: DatabaseCatalog) throws(ControlError) -> DatabaseProperty {
        let live = catalog.properties.filter { $0.deletedAt == nil }
        let pointer = json["propertyId"]?.string ?? json["property"]?.string ?? ""
        if let id = UUID(uuidString: pointer), let property = live.first(where: { $0.id == id }) { return property }
        let key = PagePath.normalized(pointer)
        if let property = live.first(where: { PagePath.normalized($0.name) == key }) { return property }
        throw ControlError(.propertyNotFound, "Нет свойства «\(pointer)»", hint: "Свойства базы: mynotion db schema <база>",
                           details: ["property": .string(pointer), "allowed": .array(live.map { .string($0.name) })])
    }
}
