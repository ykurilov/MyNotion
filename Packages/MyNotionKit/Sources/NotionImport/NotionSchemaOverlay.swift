import Databases
import Formulas
import Foundation
import NotesCore
import NotionSchemaFetch

/// Вариант выбора или статуса так, как он записан в схеме Notion.
struct OverlayOption: Equatable {
    var name: String
    var color: String
    var group: StatusGroup?
}

/// Связь по схеме: база-цель (32 hex) и название ответного свойства; `nil` — связь односторонняя.
struct DeclaredRelation: Equatable {
    var targetNotionId: String
    var pairedName: String?
}

/// Сводка по схеме: связь этой базы (столбец), название свойства в базе-цели и вычисление MyNotion.
struct PendingRollup: Equatable {
    var relationColumn: Int
    var targetName: String
    var calculation: String
}

/// Схема Notion одной базы поверх столбцов её CSV (research R19): точный тип вместо угаданного, цвета, группы статусов,
/// формулы и сводки. Чего в MyNotion нет — остаётся тип по значениям, а причина идёт в отчёт.
struct DatabaseSchemaOverlay {
    struct Column {
        var kind: ColumnKind
        var options: [OverlayOption] = []
        var relation: DeclaredRelation?
        var rollup: PendingRollup?
        /// Выражение Notion; переводится позже, когда у всех столбцов есть id.
        var formula: String?
    }

    enum Resolution {
        case column(Column)
        /// Тип остаётся угаданным; `note` — строка отчёта.
        case keepGuess(note: String?)
    }

    let schema: NotionDatabaseSchema
    let fetched: NotionSchemaFetchResult

    var propertyNamesById: [String: String] {
        Dictionary(schema.properties.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    func resolve(_ name: String, values: [String], header: [String], plan: NotionExportPlan) -> Resolution {
        guard let property = schema.property(named: name) else { return .keepGuess(note: nil) }
        switch property.kind {
        case .text: return .column(Column(kind: .text))
        case .checkbox: return .column(Column(kind: .checkbox))
        case .url: return .column(Column(kind: .url))
        case .email: return .column(Column(kind: .email))
        case .phone: return .column(Column(kind: .phone))
        case .date: return .column(Column(kind: .date))
        case .createdTime: return .column(Column(kind: .createdTime))
        case .lastEditedTime: return .column(Column(kind: .lastEditedTime))
        case .number(let format): return .column(Column(kind: .number(format: format)))
        case .uniqueId(let prefix): return .column(Column(kind: .uniqueId(prefix: prefix)))
        case .select(let options):
            let all = Self.withExtras(options.map { OverlayOption(name: $0.name, color: $0.color) }, values: values, multi: false)
            return .column(Column(kind: .options(multi: false, names: all.map(\.name)), options: all))
        case .multiSelect(let options):
            let all = Self.withExtras(options.map { OverlayOption(name: $0.name, color: $0.color) }, values: values, multi: true)
            return .column(Column(kind: .options(multi: true, names: all.map(\.name)), options: all))
        case .status(let options, let groups):
            let all = Self.statusOptions(options, groups: groups, values: values)
            return .column(Column(kind: .status(names: all.map(\.name)), options: all))
        case .formula(let expression):
            return .column(Column(kind: .formula(stored: ""), formula: expression))
        case .relation(let relation):
            return relationColumn(relation, plan: plan)
        case .rollup(let rollup):
            return rollupColumn(name, rollup, header: header)
        case .title, .files, .unsupported:
            return .keepGuess(note: nil)
        }
    }

    // MARK: Связь и сводка

    private func targetNotionId(of relation: NotionRelation) -> String? {
        relation.targetDatabaseId ?? relation.targetDataSourceId.flatMap(fetched.databaseId(ofDataSource:))
    }

    private func relationColumn(_ relation: NotionRelation, plan: NotionExportPlan) -> Resolution {
        // База-цель вне выгрузки: связь не из чего собрать — тип по значениям, как без схемы.
        guard let target = targetNotionId(of: relation), let index = plan.pageByNotionId[target], plan.pages[index].isTable else {
            return .keepGuess(note: nil)
        }
        return .column(Column(kind: .relation, relation: DeclaredRelation(targetNotionId: target, pairedName: relation.pairedPropertyName)))
    }

    private func rollupColumn(_ name: String, _ rollup: NotionRollup, header: [String]) -> Resolution {
        func keepValues(_ reason: String) -> Resolution {
            .keepGuess(note: "«\(name)» — сводка Notion осталась значениями из выгрузки: \(reason)")
        }
        guard let calculation = rollup.calculation else {
            return keepValues("вычисления «\(rollup.function)» в MyNotion нет")
        }
        guard let relationColumn = header.firstIndex(of: rollup.relationPropertyName),
              case .relation(let relation)? = schema.property(named: rollup.relationPropertyName)?.kind,
              let target = targetNotionId(of: relation)
        else {
            return keepValues("связь «\(rollup.relationPropertyName)» не перенесена")
        }
        guard let targetSchema = fetched.schemas[target] else {
            return keepValues("схема базы, на которую ведёт связь «\(rollup.relationPropertyName)», не прочитана")
        }
        guard targetSchema.property(named: rollup.targetPropertyName) != nil else {
            return keepValues("в связанной базе нет свойства «\(rollup.targetPropertyName)»")
        }
        return .column(Column(kind: .rollup, rollup: PendingRollup(relationColumn: relationColumn, targetName: rollup.targetPropertyName,
                                                                   calculation: calculation)))
    }

    // MARK: Варианты

    /// Значения из таблицы, которых нет среди вариантов схемы (вариант удалили, а значения остались), — обычным цветом.
    private static func withExtras(_ options: [OverlayOption], values: [String], multi: Bool) -> [OverlayOption] {
        var all = options
        var known = Set(options.map(\.name))
        for value in values {
            for part in multi ? ColumnGuess.multiParts(value) : [value] where known.insert(part).inserted {
                all.append(OverlayOption(name: part, color: "default"))
            }
        }
        return all
    }

    /// Варианты статуса по группам Notion: «To-do», «In progress», «Complete»; без группы — в «To-do».
    private static func statusOptions(_ options: [NotionOption], groups: [NotionStatusGroup], values: [String]) -> [OverlayOption] {
        var groupOf: [String: StatusGroup] = [:]
        for group in groups {
            for name in group.optionNames { groupOf[name] = StatusGroup(rawValue: group.group.rawValue) }
        }
        var all = options.map { OverlayOption(name: $0.name, color: $0.color, group: groupOf[$0.name] ?? .todo) }
        let known = Set(options.map(\.name))
        var extras = Set<String>()
        for value in values where !known.contains(value) && extras.insert(value).inserted {
            all.append(OverlayOption(name: value, color: "default", group: .todo))
        }
        let order = StatusGroup.allCases
        return all.enumerated().sorted { left, right in
            let a = order.firstIndex(of: left.element.group ?? .todo) ?? 0, b = order.firstIndex(of: right.element.group ?? .todo) ?? 0
            return a != b ? a < b : left.offset < right.offset
        }.map(\.element)
    }
}

/// Схема столбцов для проверки формул при импорте: id заранее известны, типы — по выбранным видам столбцов.
struct PlannedFormulaSchema: FormulaSchema {
    let properties: [FormulaProperty]

    func property(_ nameOrId: String, inDatabase database: String?) -> FormulaProperty? {
        guard database == nil else { return nil }
        return properties.first { $0.id == nameOrId.lowercased() } ?? properties.first { $0.name == nameOrId }
    }
}
