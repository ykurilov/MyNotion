import ControlProtocol
import Databases
import Formulas
import Foundation
import NotesCore

/// База и её схема (T047): создать базу, прочитать схему, свойства всех типов с настройками, смена типа, варианты.
/// Настройки на входе — как у 004, но связь, сводка и формула задаются именами (contracts/commands.md, «db prop»).
enum SchemaHandlers {
    static let all: [String: CommandHandler] = [
        "db.create": create,
        "db.schema": schema,
        "db.prop.add": addProperty,
        "db.prop.update": updateProperty,
        "db.prop.type": changeType,
        "db.prop.move": moveProperty,
        "db.prop.duplicate": { session in
            let (database, property) = try session.databaseProperty()
            let copy = try session.databases.duplicateProperty(property.id, in: nil)
            return try session.propertyResult(copy.id, of: database.page.id, "✓ Копия свойства «\(copy.name)»")
        },
        "db.prop.delete": { session in
            let (database, property) = try session.databaseProperty()
            try session.databases.setDeleted(property.id, true)
            return CommandResult(["property": DatabaseJSON.property(property, catalog: database.catalog)],
                                 text: "✓ Свойство «\(property.name)» удалено: вернуть — mynotion db prop restore")
        },
        "db.prop.restore": restoreProperty,
        "db.option.add": addOption,
        "db.option.rename": { session in
            let (_, property, option) = try session.databaseOption()
            try session.databases.renameOption(option.id, to: session.string("name") ?? "")
            return try session.optionResult(option.id, of: property, "✓ Вариант переименован")
        },
        "db.option.color": { session in
            let (_, property, option) = try session.databaseOption()
            try session.databases.setOptionColor(option.id, to: try color(session.string("color")) ?? .default)
            return try session.optionResult(option.id, of: property, "✓ Цвет варианта «\(option.name)»")
        },
        "db.option.move": moveOption,
        "db.option.delete": { session in
            let (_, property, option) = try session.databaseOption()
            try session.databases.deleteOption(option.id)
            return CommandResult(["option": DatabaseJSON.option(option)], text: "✓ Вариант «\(option.name)» удалён из «\(property.name)»")
        },
    ]

    // MARK: База

    static let create: CommandHandler = { session in
        let parent = try session.page("parent")
        let isInline = session.flag("inline")
        let after = try session.string("after").map { _ in try session.block("after", inPage: parent.id) }
        try await session.willWrite(parent.id)
        let created = try session.databases.createDatabase(in: parent.id, isInline: isInline, title: session.string("title") ?? "",
                                                           linkAt: after.map { .after(blockId: $0.id) })
        session.touch([parent.id, created.databaseId])
        let data: ControlJSON = ["database": try session.databasePageJSON(created.databaseId), "viewId": .string(created.viewId.controlText),
                                 "blockId": created.blockId.map { .string($0.controlText) } ?? .null]
        return CommandResult(data, text: "✓ База «\(session.string("title") ?? "")» создана: \(created.databaseId.controlText)")
    }

    static let schema: CommandHandler = { session in
        let database = try session.database()
        let formulas = try DatabaseFormulaSchema.read(database.page.id, in: session.host.store)
        let views = try ViewQuery.views(of: database.page.id, in: session.host.store)
        let properties = database.catalog.properties.map { DatabaseJSON.property($0, catalog: database.catalog, formulas: formulas) }
        let data: ControlJSON = ["database": try session.databasePageJSON(database.page.id), "properties": .array(properties),
                                 "views": .array(views.map { DatabaseJSON.view($0, catalog: database.catalog) })]
        let lines = database.catalog.properties.map { "  \($0.name) — \($0.kind.rawValue)" }
        return CommandResult(data, text: (["\(database.page.displayTitle): свойств \(properties.count), видов \(views.count)"] + lines)
            .joined(separator: "\n"))
    }

    // MARK: Свойства

    static let addProperty: CommandHandler = { session in
        let database = try session.database()
        let name = session.string("name") ?? ""
        let kind = PropertyKind(rawValue: session.string("type") ?? "")
        let config = session.args["config"] ?? [:]
        let operations = session.databases
        let property: DatabaseProperty
        switch kind {
        case .relation:
            let target = try session.relationTarget(config)
            property = try operations.addRelation(to: database.page.id, name: name, target: target.page.id,
                                                  limit: try relationLimit(config["limit"]) ?? .none, relatedName: config["related"]?.string)
        default:
            property = try operations.addProperty(to: database.page.id, name: name, kind: kind,
                                                  config: merged(.emptyObject, config, except: specialKeys(kind)))
            try session.applySpecialConfig(config, formula: kind == .formula ? config["formula"]?.string : nil, to: property, in: database)
        }
        if let after = session.string("after") {
            let anchor = try session.databaseRefs.property(after, in: database.catalog)
            let others = try session.catalog(of: database.page.id).properties.filter { $0.id != property.id }
            try operations.moveProperty(property.id, to: (others.firstIndex { $0.id == anchor.id } ?? others.count - 1) + 1)
        }
        return try session.propertyResult(property.id, of: database.page.id, "✓ Свойство «\(name)» (\(kind.rawValue)) добавлено")
    }

    static let updateProperty: CommandHandler = { session in
        let (database, property) = try session.databaseProperty()
        if let name = session.string("name") { try session.databases.renameProperty(property.id, to: name) }
        let config = session.args["config"] ?? [:]
        if property.kind == .relation {
            if let limit = try relationLimit(config["limit"]) { try session.databases.setRelationLimit(property.id, limit) }
            switch config["related"] {
            case .bool(let enabled)?: try session.databases.setRelatedProperty(of: property.id, enabled: enabled)
            case .string(let name)?: try session.databases.setRelatedProperty(of: property.id, enabled: true, name: name)
            default: break
            }
            if let target = config["target"], try session.relationTarget(config).page.id != property.relationTarget {
                throw ControlError(.invalidValue, "Связь не переводится на другую базу: \(target)",
                                   hint: "Новая связь: mynotion db prop add … --type relation", details: ["argument": "target"])
            }
        }
        let rest = merged(property.config, config, except: specialKeys(property.kind))
        if rest != property.config { try session.databases.setPropertyConfig(property.id, rest) }
        try session.applySpecialConfig(config, formula: session.string("formula") ?? config["formula"]?.string, to: property, in: database)
        return try session.propertyResult(property.id, of: database.page.id, "✓ Свойство «\(property.name)» изменено")
    }

    static let changeType: CommandHandler = { session in
        let (database, property) = try session.databaseProperty()
        let kind = PropertyKind(rawValue: session.string("type") ?? "")
        let rows = try session.rowCount(of: database.page.id)
        if rows >= DatabaseOperations.backgroundRewriteThreshold {
            // Большая база — фоновой перезаписью, как в окне; ответ — после её итога.
            session.report(ControlProgress(done: 0, total: rows, stage: "Смена типа «\(property.name)»"))
            try await session.databases.startChangeType(property.id, to: kind).value
        } else {
            try session.databases.changeType(property.id, to: kind)
        }
        return try session.propertyResult(property.id, of: database.page.id, "✓ «\(property.name)» теперь \(kind.rawValue)")
    }

    static let moveProperty: CommandHandler = { session in
        let (database, property) = try session.databaseProperty()
        var index = 0
        if let after = session.string("after") {
            let anchor = try session.databaseRefs.property(after, in: database.catalog)
            let others = database.catalog.properties.filter { $0.id != property.id }
            index = (others.firstIndex { $0.id == anchor.id } ?? -1) + 1
        }
        try session.databases.moveProperty(property.id, to: index)
        return try session.propertyResult(property.id, of: database.page.id, "✓ Свойство «\(property.name)» передвинуто")
    }

    static let restoreProperty: CommandHandler = { session in
        let database = try session.database()
        let pointer = session.string("property") ?? ""
        let deleted = try DatabaseCatalog.deletedProperties(of: database.page.id, in: session.host.store)
        let key = PagePath.normalized(pointer)
        guard let property = deleted.first(where: { $0.id.controlText == pointer.lowercased() })
            ?? deleted.first(where: { PagePath.normalized($0.name) == key }) else {
            throw ControlError(.propertyNotFound, "Среди удалённых свойств нет «\(pointer)»", hint: "Удалённые: " + deleted.map(\.name).joined(separator: ", "),
                               details: ["property": .string(pointer), "allowed": .array(deleted.map { .string($0.name) })])
        }
        try session.databases.setDeleted(property.id, false)
        return try session.propertyResult(property.id, of: database.page.id, "✓ Свойство «\(property.name)» возвращено")
    }

    // MARK: Варианты

    static let addOption: CommandHandler = { session in
        let (database, property) = try session.databaseProperty()
        guard [.select, .multiSelect, .status].contains(property.kind) else {
            throw ControlError(.invalidValue, "У свойства «\(property.name)» (\(property.kind.rawValue)) нет вариантов",
                               details: ["property": .string(property.name), "type": .string(property.kind.rawValue)])
        }
        let group = session.string("group").flatMap(StatusGroup.init(rawValue:))
        let option = try session.databases.createOption(in: property.id, named: session.string("option") ?? "",
                                                        color: try color(session.string("color")), group: group)
        if let after = session.string("after") {
            let anchor = try session.databaseRefs.option(after, of: property, in: database.catalog)
            try session.databases.moveOption(option.id, after: anchor.id, group: group)
        }
        return try session.optionResult(option.id, of: property, "✓ Вариант «\(option.name)» добавлен в «\(property.name)»")
    }

    static let moveOption: CommandHandler = { session in
        let (database, property, option) = try session.databaseOption()
        let group = session.string("group").flatMap(StatusGroup.init(rawValue:))
        let previous: UUID?
        if let after = session.string("after") {
            previous = try session.databaseRefs.option(after, of: property, in: database.catalog).id
        } else if session.flag("first") {
            previous = nil
        } else {
            // Только группа — в конец группы.
            let options = (database.catalog.options[property.id] ?? []).filter { $0.id != option.id }
            previous = options.last { $0.statusGroup == (group ?? option.statusGroup) }?.id
        }
        try session.databases.moveOption(option.id, after: previous, group: group)
        return try session.optionResult(option.id, of: property, "✓ Вариант «\(option.name)» передвинут")
    }

    // MARK: Настройки

    /// Ключи, которые команда переводит сама (имена → id), а не пишет в `config` как есть.
    private static func specialKeys(_ kind: PropertyKind) -> Set<String> {
        switch kind {
        case .relation: ["target", "limit", "related"]
        case .rollup: ["relation", "property", "calculation"]
        case .formula: ["formula"]
        default: []
        }
    }

    private static func merged(_ base: JSONValue, _ changes: ControlJSON, except skipped: Set<String>) -> JSONValue {
        var object = base.object ?? [:]
        for (key, value) in changes.object ?? [:] where !skipped.contains(key) {
            object[key] = value.isNull ? nil : value.core
        }
        return .object(object)
    }

    static func relationLimit(_ json: ControlJSON?) throws(ControlError) -> RelationLimit? {
        guard let json else { return nil }
        guard let limit = json.string.flatMap(RelationLimit.init(rawValue:)) else {
            throw .invalidChoice("limit", "\(json)", allowed: RelationLimit.allCases.map(\.rawValue))
        }
        return limit
    }

    static func color(_ name: String?) throws(ControlError) -> OptionColor? {
        guard let name else { return nil }
        guard let color = OptionColor(rawValue: name) else { throw .invalidChoice("color", name, allowed: OptionColor.allCases.map(\.rawValue)) }
        return color
    }
}

extension CommandSession {
    func databaseProperty() throws(ControlError) -> (ResolvedDatabase, DatabaseProperty) {
        let database = try database()
        return (database, try databaseRefs.property(string("property") ?? "", in: database.catalog))
    }

    func databaseOption() throws(ControlError) -> (ResolvedDatabase, DatabaseProperty, SelectOption) {
        let (database, property) = try databaseProperty()
        return (database, property, try databaseRefs.option(string("option") ?? "", of: property, in: database.catalog))
    }

    func propertyResult(_ propertyId: UUID, of databaseId: UUID, _ text: String) throws -> CommandResult {
        let catalog = try catalog(of: databaseId)
        guard let property = catalog.propertiesById[propertyId] else { throw NotesStoreError.invalidRecord("свойства нет") }
        let formulas = try DatabaseFormulaSchema.read(databaseId, in: host.store)
        return CommandResult(["property": DatabaseJSON.property(property, catalog: catalog, formulas: formulas)], text: text)
    }

    func optionResult(_ optionId: UUID, of property: DatabaseProperty, _ text: String) throws -> CommandResult {
        let catalog = try catalog(of: property.databaseId)
        guard let option = catalog.optionsById[optionId] else { throw NotesStoreError.invalidRecord("варианта нет") }
        return CommandResult(["option": DatabaseJSON.option(option)], text: text)
    }

    /// База-цель связи из `config.target`.
    func relationTarget(_ config: ControlJSON) throws(ControlError) -> ResolvedDatabase {
        guard let target = config["target"]?.string else {
            throw ControlError(.missingArgument, "Связи нужна база: config.target", hint: #"Пример: --config '{"target":"Проекты/Клиенты"}'"#,
                               details: ["argument": "target"])
        }
        return try databaseRefs.database(target)
    }

    /// Сводка (`relation`, `property`, `calculation` — именами) и формула (`formula` — текстом с именами свойств).
    func applySpecialConfig(_ config: ControlJSON, formula: String?, to property: DatabaseProperty, in database: ResolvedDatabase) throws {
        switch property.kind {
        case .rollup where config["relation"] != nil || config["property"] != nil || config["calculation"] != nil:
            let catalog = try catalog(of: database.page.id)
            let relation = try config["relation"]?.string.map { text throws(ControlError) in try databaseRefs.property(text, in: catalog) }
                ?? property.config["relationPropertyId"]?.string.flatMap(UUID.init(uuidString:)).flatMap { catalog.propertiesById[$0] }
            if let relation, relation.kind != .relation {
                throw ControlError(.invalidValue, "«\(relation.name)» — не связь", details: ["argument": "relation", "property": .string(relation.name)])
            }
            var target = property.config["targetPropertyId"]?.string.flatMap(UUID.init(uuidString:))
            if let name = config["property"]?.string {
                guard let targetDatabase = relation?.relationTarget else {
                    throw ControlError(.missingArgument, "Сначала связь: config.relation", details: ["argument": "relation"])
                }
                target = try databaseRefs.property(name, in: try self.catalog(of: targetDatabase)).id
            }
            let calculation: Calculation
            if let name = config["calculation"]?.string {
                guard let value = Calculation(rawValue: name) else {
                    throw ControlError.invalidChoice("calculation", name, allowed: Calculation.allCases.map(\.rawValue))
                }
                calculation = value
            } else {
                calculation = property.config["calculation"]?.string.flatMap(Calculation.init(rawValue:)) ?? .showOriginal
            }
            try databases.setRollup(property.id, relation: relation?.id, target: target, calculation: calculation)
        case .formula:
            guard let formula else { return }
            do {
                try databases.setFormula(property.id, display: formula)
            } catch let error as FormulaError {
                // Место ошибки в тексте (символы с нуля); без места — вся формула.
                let range = error.range ?? 0..<formula.count
                let details: [String: ControlJSON] = ["property": .string(property.name), "from": .number(Double(range.lowerBound)),
                                                      "to": .number(Double(range.upperBound))]
                throw ControlError(.invalidFormula, "Формула «\(property.name)»: \(error.message)", hint: "Справка по формулам: references/databases.md",
                                   details: .object(details))
            }
        default:
            break
        }
    }
}
