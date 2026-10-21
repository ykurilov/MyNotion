import Databases
import Foundation
import MarkdownExport
import NotesCore

/// База своей выгрузки по схеме `*.mynotion-database.json` (contracts/sync-v4-and-export.md): типы, варианты с цветами,
/// формулы, связи, виды, шаблоны и значения — как в выгрузке. Импорт — новая база рядом (как страницы 001): у базы,
/// свойств, вариантов, видов и строк новые id; прежние id в настройках, видах, формулах и значениях заменяются новыми
/// по всем базам выгрузки сразу, поэтому связи между ними сохраняются. Id вне выгрузки остаются как есть.
struct DatabaseSchemaImport {
    private let schemas: [Int: DatabaseSchemaFile]
    /// Прежний id → новый (строкой, как в JSON).
    private var newIds: [String: String] = [:]
    /// Страница плана для каждой строки и шаблона схемы: по индексу таблицы и прежнему id строки.
    private var rowPages: [Int: [String: Int]] = [:]

    init(schemas: [Int: DatabaseSchemaFile]) {
        self.schemas = schemas
    }

    /// Новые id всех записей схем; строки — страницы плана (по файлу), строке без файла — новая страница.
    mutating func assignIds(in plan: inout NotionExportPlan) throws {
        for (index, schema) in schemas.sorted(by: { $0.key < $1.key }) {
            newIds[schema.databaseId] = plan.pages[index].id.databaseText
            for property in schema.properties { newIds[property.id] = UUID.timeOrdered().databaseText }
            for option in schema.options { newIds[option.id] = UUID.timeOrdered().databaseText }
            for view in schema.views { newIds[view.id] = UUID.timeOrdered().databaseText }

            // Файл строки — от папки схемы: ключ страницы плана — путь без `.md` от корня выгрузки.
            let folder = plan.pages[index].key.split(separator: "/").dropLast().map(String.init)
            var byKey: [String: Int] = [:]
            for child in plan.pages[index].children { byKey[plan.pages[child].key] = child }
            var pages: [String: Int] = [:]
            for row in schema.rows + schema.templates {
                let components = folder + row.file.split(separator: "/").map(String.init)
                let key = NotionExportReader.normalized(components.joined(separator: "/"))
                let stem = key.hasSuffix(".md") ? String(key.dropLast(3)) : key
                let pageIndex = byKey[stem] ?? plan.appendSyntheticRow(title: row.title, database: index)
                plan.pages[pageIndex].title = row.title
                pages[row.id] = pageIndex
                newIds[row.id] = plan.pages[pageIndex].id.databaseText
            }
            rowPages[index] = pages
        }
    }

    func plan(_ index: Int, in plan: inout NotionExportPlan) throws -> PlannedDatabase {
        guard let schema = schemas[index] else { throw NotionImportError.notAnExport }
        let databaseId = plan.pages[index].id
        func id(_ old: String) -> UUID { UUID(uuidString: newIds[old] ?? old) ?? UUID() }
        func key(_ raw: String) -> FractionalSortKey { FractionalSortKey(rawValue: raw) ?? .between(nil, nil) }

        let properties = schema.properties.map { property in
            DatabaseProperty(id: id(property.id), databaseId: databaseId, name: property.name, kind: PropertyKind(rawValue: property.type),
                             config: remap(property.config, deep: true), sortKey: key(property.sortKey), deletedAt: property.deletedAt)
        }
        let options = schema.options.map { option in
            SelectOption(id: id(option.id), propertyId: id(option.propertyId), name: option.name, colorName: option.color,
                         sortKey: key(option.sortKey), statusGroup: option.statusGroup.flatMap(StatusGroup.init(rawValue:)),
                         deletedAt: option.deletedAt, fieldClocks: .init())
        }
        let views = schema.views.map { view in
            DatabaseView(id: id(view.id), databaseId: databaseId, name: view.name, type: view.type, sortKey: key(view.sortKey),
                         filter: view.filter.map { remap($0, deep: true) }, sorts: remap(view.sorts, deep: true),
                         columns: remap(view.columns, deep: true), group: view.group.map { remap($0, deep: true) },
                         layoutOptions: remap(view.layoutOptions, deep: true))
        }
        let pages = rowPages[index] ?? [:]
        var rows: [PlannedRow] = []
        for (row, isTemplate) in schema.rows.map({ ($0, false) }) + schema.templates.map({ ($0, true) }) {
            guard let pageIndex = pages[row.id] else { continue }
            var planned = PlannedRow(pageIndex: pageIndex, isTemplate: isTemplate, createdAt: row.createdAt, updatedAt: row.updatedAt)
            for (propertyId, value) in row.cells.sorted(by: { $0.key < $1.key }) {
                planned.cells.append((id(propertyId), value == .null ? nil : remap(value, deep: false)))
            }
            for (propertyId, targets) in row.relations.sorted(by: { $0.key < $1.key }) {
                planned.relations.append((id(propertyId), targets.compactMap { UUID(uuidString: newIds[$0] ?? $0) }))
            }
            rows.append(planned)
            plan.pages[pageIndex].sortKey = key(row.sortKey)
        }
        // Подстраницы базы — строки по их ключам порядка, затем шаблоны.
        let rowIndices = rows.filter { !$0.isTemplate }.map(\.pageIndex)
        let templateIndices = rows.filter(\.isTemplate).map(\.pageIndex)
        let others = plan.pages[index].children.filter { !rowIndices.contains($0) && !templateIndices.contains($0) }
        plan.pages[index].children = rowIndices + templateIndices + others

        let rowOrders = schema.rowOrders.map { (viewId: id($0.viewId), rowId: id($0.rowId), sortKey: key($0.sortKey)) }
        let titles = Dictionary(uniqueKeysWithValues: schemas.values.map { ($0.databaseId, $0.title) })
        let summaryLines = schema.properties.filter { $0.deletedAt == nil }.map { property in
            var line = "\(property.name) — \(PropertyKindTitles.title(PropertyKind(rawValue: property.type)))"
            if property.type == PropertyKind.relation.rawValue, let target = property.config["targetDatabaseId"]?.string {
                line += " с «\(titles[target] ?? plan.pages[index].title)»"
                if property.config["pairedPropertyId"] != nil { line += ", двусторонняя" }
            }
            return line
        }
        return PlannedDatabase(pageIndex: index,
                               schema: DatabaseSchema(pageId: databaseId, isInline: schema.isInline,
                                                      defaultTemplateId: schema.defaultTemplateId.map(id)),
                               properties: properties, options: options, views: views, rowOrders: rowOrders, rows: rows,
                               summary: DatabaseImportSummary(title: schema.title, rowCount: schema.rows.count,
                                                              templateCount: schema.templates.count, properties: summaryLines, notes: []),
                               isFromNotion: false)
    }

    /// Прежние id → новые. `deep` — ещё и внутри текста (формула хранит `prop("<id>")`).
    func remap(_ value: JSONValue, deep: Bool) -> JSONValue {
        switch value {
        case .string(let text):
            if let mapped = newIds[text] { return .string(mapped) }
            guard deep, text.count > 36 else { return value }
            return .string(Self.replacingIds(in: text, newIds))
        case .array(let items): return .array(items.map { remap($0, deep: deep) })
        case .object(let object): return .object(object.mapValues { remap($0, deep: deep) })
        default: return value
        }
    }

    private static let uuidPattern = try! NSRegularExpression(pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    static func replacingIds(in text: String, _ newIds: [String: String]) -> String {
        let ns = text as NSString
        var result = text
        for match in uuidPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let old = ns.substring(with: match.range)
            guard let new = newIds[old.lowercased()] else { continue }
            result = (result as NSString).replacingCharacters(in: match.range, with: new)
        }
        return result
    }
}
