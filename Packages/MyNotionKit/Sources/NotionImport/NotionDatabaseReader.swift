import Databases
import Foundation
import MarkdownExport
import NotesCore
import NotionSchemaFetch

/// Итог импорта одной базы для отчёта (contracts/sync-v4-and-export.md, «Отчёт»).
public struct DatabaseImportSummary: Sendable, Equatable, Codable {
    public var title: String
    public var rowCount: Int
    public var templateCount: Int
    /// «Статус — выбор», «Проект — связь с «Проекты», двусторонняя».
    public var properties: [String]
    /// Что у этой базы перенесено не целиком.
    public var notes: [String]
    /// Схема базы дочитана из Notion по ключу: типы, цвета, формулы и сводки — не угаданы, а взяты из неё.
    public var schemaApplied: Bool

    public init(title: String, rowCount: Int, templateCount: Int, properties: [String], notes: [String], schemaApplied: Bool = false) {
        self.title = title
        self.rowCount = rowCount
        self.templateCount = templateCount
        self.properties = properties
        self.notes = notes
        self.schemaApplied = schemaApplied
    }

    /// Прежние отчёты в журнале — без поля о схеме.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(title: try container.decode(String.self, forKey: .title), rowCount: try container.decode(Int.self, forKey: .rowCount),
                  templateCount: try container.decode(Int.self, forKey: .templateCount),
                  properties: try container.decode([String].self, forKey: .properties), notes: try container.decode([String].self, forKey: .notes),
                  schemaApplied: try container.decodeIfPresent(Bool.self, forKey: .schemaApplied) ?? false)
    }

    /// Строка отчёта у выгрузки без «Include subpages».
    public static let withoutSubpagesNote = "Выгрузка без подстраниц: у строк нет текста страниц"

    static func outsideRelationNote(_ name: String) -> String {
        "«\(name)» ссылается на строки вне выгрузки — перенесено текстом"
    }
}

/// Строка базы или шаблон, готовые к записи: значения уже в JSON ячеек, связи — id страниц-целей.
struct PlannedRow {
    var pageIndex: Int
    var isTemplate = false
    var cells: [(propertyId: UUID, value: JSONValue?)] = []
    var relations: [(propertyId: UUID, targets: [UUID])] = []
    var createdAt: Date?
    var updatedAt: Date?
}

/// База выгрузки, готовая к записи: записи схемы с новыми id и строки по страницам плана.
struct PlannedDatabase {
    var pageIndex: Int
    var schema: DatabaseSchema
    var properties: [DatabaseProperty]
    var options: [SelectOption]
    var views: [DatabaseView]
    var rowOrders: [(viewId: UUID, rowId: UUID, sortKey: FractionalSortKey)] = []
    /// Своя выгрузка: записи связей как были (с ключами порядка); `nil` — связи из списков строк.
    var links: [RelationLink]?
    var rows: [PlannedRow] = []
    var summary: DatabaseImportSummary
    /// Своя выгрузка MyNotion (со схемой) — без строк отчёта о потерях Notion.
    var isFromNotion: Bool
    /// Сырые связи Notion до второго прохода: колонка → страница строки → 32 hex целей.
    var pendingRelations: [Int: [Int: [String]]] = [:]
    /// Связи, о которых сказала схема Notion (даже если в таблице они пусты): колонка → цель и пара.
    var declaredRelations: [Int: DeclaredRelation] = [:]
    /// Сводки по схеме Notion: колонка → связь, свойство цели и вычисление; id целей находятся вторым проходом.
    var pendingRollups: [Int: PendingRollup] = [:]
    /// Значения сводок из выгрузки и угаданный тип столбца: если вторым проходом сводку собрать не удалось, остаются они.
    var rollupFallbacks: [Int: RollupFallback] = [:]
}

/// Столбец сводки Notion как он был в таблице: тип по значениям и текст ячейки каждой строки (по странице строки).
struct RollupFallback {
    var kind: ColumnKind
    var texts: [Int: String] = [:]
}

/// Базы выгрузки (research R18): место, строки ↔ файлы, типы по значениям, связи по 32 hex, отчёт. Своя выгрузка
/// со схемой `*.mynotion-database.json` читается по схеме (`DatabaseSchemaImport`). Только план — пишет `NotionImporter`.
struct NotionDatabaseReader {
    var timeZone: TimeZone = .current
    /// Схемы баз, дочитанные из Notion по ключу, и причины, почему какие-то не прочитаны (Q3, research R19).
    var schema = NotionSchemaFetchResult()

    /// Общие потери выгрузки Notion — в отчёт, если в ней были базы Notion.
    static let notionNotices = [
        "Формулы и сводки Notion приходят готовыми значениями — числом или текстом",
        "Статусы Notion стали выбором: в выгрузке они неотличимы",
        "Цвета вариантов, виды, фильтры и сортировки в выгрузке Notion не передаются: цвета — по кругу, вид — один, «Таблица»",
        "Люди («Человек», «Создал», «Изменил») — текстом с именами",
    ]

    /// То, что не передаётся и со схемой: типы, цвета, формулы и сводки она возвращает, виды и людей — нет.
    static let noticesWithSchema = [
        "Виды, фильтры и сортировки в выгрузке Notion не передаются: вид один, «Таблица»",
        "Люди («Человек», «Создал», «Изменил») — текстом с именами",
    ]

    /// Базы плана по индексу страницы-базы. Строкам без файла (выгрузка без подстраниц) добавляет страницы,
    /// подстраницы базы ставит по порядку строк CSV, шаблоны — после строк.
    func read(_ plan: inout NotionExportPlan) throws -> [Int: PlannedDatabase] {
        let tables = plan.pages.indices.filter { plan.pages[$0].isTable }
        guard !tables.isEmpty else { return [:] }
        var schemas: [Int: DatabaseSchemaFile] = [:]
        for index in tables {
            guard let file = plan.pages[index].schemaFile else { continue }
            do {
                schemas[index] = try DatabaseSchemaFile.decoded(from: Data(contentsOf: file))
            } catch {
                throw NotionImportError.cannotRead("схема «\(file.lastPathComponent)» не читается")
            }
        }
        var result: [Int: PlannedDatabase] = [:]
        var own = DatabaseSchemaImport(schemas: schemas)
        try own.assignIds(in: &plan)
        for index in tables {
            try Task.checkCancellation()
            if schemas[index] != nil {
                result[index] = try own.plan(index, in: &plan)
            } else {
                result[index] = notionPlan(index, in: &plan)
            }
        }
        resolveNotionRelations(&result, plan: plan)
        return result
    }

    // MARK: База Notion

    /// Сырые связи строк базы Notion до второго прохода: по колонке — 32 hex целей каждой строки.
    private func notionPlan(_ index: Int, in plan: inout NotionExportPlan) -> PlannedDatabase {
        let page = plan.pages[index]
        let databaseId = page.id
        let header = (page.csvRows.first ?? ["Name"]).map { $0.trimmingCharacters(in: .whitespaces) }
        let csvRows = page.csvRows.dropFirst().map { row in
            header.indices.map { $0 < row.count ? row[$0].trimmingCharacters(in: .whitespaces) : "" }
        }

        // Строки ↔ файлы: по названию и порядку, у одинаковых названий — файл с совпадающими строками свойств.
        let files = page.children.filter { !plan.pages[$0].isTable }
        // Файлы по названию, по порядку имён: тысячи строк сопоставляются за один проход.
        var unusedByTitle: [String: [Int]] = [:]
        for file in files { unusedByTitle[Self.titleKey(plan.pages[file].title), default: []].append(file) }
        var rowPages: [Int] = []
        var matched: Set<Int> = []
        for values in csvRows {
            let title = Self.titleKey(values.first ?? "")
            let candidates = unusedByTitle[title] ?? []
            let scores = candidates.count > 1 ? candidates.map { Self.agreement(plan.pages[$0].propertyLines, values, header) } : [0]
            if let best = scores.max(), let position = scores.firstIndex(of: best), position < candidates.count {
                let chosen = candidates[position]
                unusedByTitle[title]?.remove(at: position)
                plan.pages[chosen].title = values.first ?? ""
                rowPages.append(chosen)
                matched.insert(chosen)
            } else {
                rowPages.append(plan.appendSyntheticRow(title: values.first ?? "", database: index))
            }
        }
        let matchedFiles = matched.count
        let templates = files.filter { !matched.contains($0) }
        plan.pages[index].children = rowPages + templates

        // Типы колонок: по всем значениям, а если схема из Notion прочитана — по ней (research R19).
        var properties: [DatabaseProperty] = []
        var options: [SelectOption] = []
        var summaryLines: [String] = []
        var notes: [String] = []
        var sortKey: FractionalSortKey?
        var columnKinds: [ColumnKind] = []
        var guessedKinds: [ColumnKind] = []
        var overlayColumns: [Int: DatabaseSchemaOverlay.Column] = [:]
        let notionId = NotionExportReader.notionId(in: page.key)
        let overlay = notionId.flatMap { schema.schemas[$0] }.map { DatabaseSchemaOverlay(schema: $0, fetched: schema) }
        if overlay == nil, let failure = schema.failures.first(where: { $0.databaseId == notionId }) {
            notes.append("Схема из Notion не прочитана, типы угаданы по значениям. " + failure.reason.explanation)
        }
        for (column, name) in header.enumerated() {
            let values = csvRows.map { $0[column] }.filter { !$0.isEmpty }
            var kind = column == 0 ? ColumnKind.title : ColumnGuess.kind(name: name, values: values, timeZone: timeZone)
            guessedKinds.append(kind)
            if column > 0, let overlay {
                switch overlay.resolve(name, values: values, header: header, plan: plan) {
                case .column(let resolved):
                    kind = resolved.kind
                    overlayColumns[column] = resolved
                case .keepGuess(let note):
                    if let note { notes.append(note) }
                }
            }
            if case .relation = kind, !values.allSatisfy({ hexes in
                RelationText.targets(hexes).allSatisfy { plan.pageByNotionId[$0] != nil }
            }) {
                kind = .text
                overlayColumns[column] = nil
                notes.append(DatabaseImportSummary.outsideRelationNote(name))
            }
            columnKinds.append(kind)
        }

        // Формулы Notion — формулами MyNotion; не переведённая остаётся значениями из выгрузки.
        let propertyIds = header.map { _ in UUID.timeOrdered() }
        if let overlay, overlayColumns.values.contains(where: { $0.formula != nil }) {
            let titles = header.map { $0.isEmpty ? "Без названия" : $0 }
            var drafts = header.indices.map { column in
                DatabaseProperty(id: propertyIds[column], databaseId: databaseId, name: titles[column], kind: columnKinds[column].propertyKind,
                                 config: columnKinds[column].config, sortKey: .between(nil, nil))
            }
            for column in overlayColumns.keys.sorted() {
                guard let expression = overlayColumns[column]?.formula else { continue }
                let formulaSchema = PlannedFormulaSchema(properties: drafts.map(DatabaseFormulaSchema.formulaProperty))
                switch NotionFormula.translate(expression, propertyNamesById: overlay.propertyNamesById, schema: formulaSchema) {
                case .translated(let stored, _):
                    columnKinds[column] = .formula(stored: stored)
                    drafts[column].config = columnKinds[column].config
                case .notTranslated(let reason):
                    columnKinds[column] = guessedKinds[column]
                    overlayColumns[column] = nil
                    notes.append("«\(titles[column])» — формула Notion не перенесена (\(reason)): значения из выгрузки")
                }
            }
        }

        for (column, name) in header.enumerated() {
            let kind = columnKinds[column]
            sortKey = .between(sortKey, nil)
            let property = DatabaseProperty(id: propertyIds[column], databaseId: databaseId, name: name.isEmpty ? "Без названия" : name,
                                            kind: kind.propertyKind, config: kind.config, sortKey: sortKey!)
            properties.append(property)
            if let names = kind.optionNames {
                // Варианты по схеме — со своими цветами и группами; угаданные — по порядку появления, цвета по кругу.
                let styled = overlayColumns[column]?.options ?? names.enumerated().map { position, optionName in
                    OverlayOption(name: optionName, color: OptionColor.allCases[position % OptionColor.allCases.count].rawValue)
                }
                var optionKey: FractionalSortKey?
                for option in styled {
                    optionKey = .between(optionKey, nil)
                    options.append(SelectOption(propertyId: property.id, name: option.name, color: OptionColor(rawValue: option.color) ?? .default,
                                                sortKey: optionKey!, statusGroup: option.group))
                }
            }
            summaryLines.append(kind.reportLine(name: property.name))
        }
        let optionIds = Dictionary(grouping: options, by: \.propertyId).mapValues { list in
            Dictionary(list.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        }

        // Значения строк и шаблонов.
        var rows: [PlannedRow] = []
        var pending: [Int: [Int: [String]]] = [:]
        var rollupTexts: [Int: [Int: String]] = [:]
        func plannedRow(_ pageIndex: Int, values: (Int) -> String?, isTemplate: Bool) -> PlannedRow {
            var row = PlannedRow(pageIndex: pageIndex, isTemplate: isTemplate)
            for column in header.indices.dropFirst() {
                guard let text = values(column), !text.isEmpty else { continue }
                let property = properties[column]
                switch columnKinds[column] {
                case .createdTime:
                    row.createdAt = ColumnGuess.date(text, timeZone: timeZone).flatMap { DateText.parse($0.start, timeZone: timeZone.identifier) }
                case .lastEditedTime:
                    row.updatedAt = ColumnGuess.date(text, timeZone: timeZone).flatMap { DateText.parse($0.start, timeZone: timeZone.identifier) }
                case .relation:
                    pending[column, default: [:]][pageIndex] = RelationText.targets(text)
                case .rollup:
                    rollupTexts[column, default: [:]][pageIndex] = text
                default:
                    if let value = columnKinds[column].value(text, optionIds: optionIds[property.id] ?? [:], timeZone: timeZone) {
                        row.cells.append((property.id, value))
                    }
                }
            }
            return row
        }
        for (values, pageIndex) in zip(csvRows, rowPages) {
            rows.append(plannedRow(pageIndex, values: { values[$0] }, isTemplate: false))
        }
        for pageIndex in templates {
            let lines = plan.pages[pageIndex].propertyLines
            rows.append(plannedRow(pageIndex, values: { lines[header[$0]] }, isTemplate: true))
        }
        if !csvRows.isEmpty, matchedFiles == 0 { notes.insert(DatabaseImportSummary.withoutSubpagesNote, at: 0) }

        let view = DatabaseView(databaseId: databaseId, sortKey: .between(nil, nil),
                                columns: .array(Self.viewColumns(header: header, viewFile: page.viewFile, properties: properties)),
                                layoutOptions: ["openRowsIn": "sidePeek", "loadLimit": 50, "wrapAllContent": false])
        let parentLinks = page.parent.map { parent in
            plan.pages[parent].blocks.contains { NotionExportReader.linkedPage($0, from: parent, in: plan) == index }
        } ?? false
        var database = PlannedDatabase(pageIndex: index, schema: DatabaseSchema(pageId: databaseId, isInline: parentLinks),
                                       properties: properties, options: options, views: [view], rows: rows,
                                       summary: DatabaseImportSummary(title: page.title, rowCount: csvRows.count, templateCount: templates.count,
                                                                      properties: summaryLines, notes: notes, schemaApplied: overlay != nil),
                                       isFromNotion: true)
        // Связь по схеме есть и в пустом столбце: без неё у свойства не было бы базы-цели.
        for (column, overlayColumn) in overlayColumns {
            if let relation = overlayColumn.relation, case .relation = columnKinds[column] {
                if pending[column] == nil { pending[column] = [:] }
                database.declaredRelations[column] = relation
            }
            if let rollup = overlayColumn.rollup {
                database.pendingRollups[column] = rollup
                database.rollupFallbacks[column] = RollupFallback(kind: Self.valueKind(guessedKinds[column]), texts: rollupTexts[column] ?? [:])
            }
        }
        database.pendingRelations = pending
        return database
    }

    /// Связи Notion вторым проходом: цели — строки других баз по 32 hex; столбец-пара во второй базе с теми же
    /// связями — двусторонняя связь.
    private func resolveNotionRelations(_ databases: inout [Int: PlannedDatabase], plan: NotionExportPlan) {
        var databaseOfRow: [Int: Int] = [:]
        for (index, database) in databases { for row in database.rows { databaseOfRow[row.pageIndex] = index } }
        // Свойство-связь: база, колонка, база-цель, пары (строка, цель) — индексы страниц плана.
        // `declaredPair` — ответное свойство по схеме Notion: `nil` — схемы нет (пара по значениям), `.some(nil)` — пары нет.
        struct Relation { var database: Int; var column: Int; var target: Int; var pairs: Set<[Int]>; var declaredPair: String?? }
        var relations: [Relation] = []
        for (index, database) in databases.sorted(by: { $0.key < $1.key }) {
            for (column, byRow) in database.pendingRelations.sorted(by: { $0.key < $1.key }) {
                var targetDatabase: Int?
                var pairs: Set<[Int]> = []
                for (row, hexes) in byRow {
                    for hex in hexes {
                        guard let target = plan.pageByNotionId[hex] else { continue }
                        targetDatabase = targetDatabase ?? databaseOfRow[target]
                        pairs.insert([row, target])
                    }
                }
                let declared = database.declaredRelations[column]
                let declaredTarget = declared.flatMap { plan.pageByNotionId[$0.targetNotionId] }.flatMap { databases[$0] == nil ? nil : $0 }
                relations.append(Relation(database: index, column: column, target: declaredTarget ?? targetDatabase ?? index, pairs: pairs,
                                          declaredPair: declared.map { $0.pairedName }))
            }
        }
        func columnName(_ relation: Relation) -> String { databases[relation.database]!.properties[relation.column].name }
        func isSame(_ a: Relation, _ b: Relation) -> Bool { a.database == b.database && a.column == b.column }
        /// Ответное свойство: по схеме (с любой из двух сторон), а без схемы — то, чьи связи зеркальны.
        func pairOf(_ relation: Relation) -> Relation? {
            if let declared = relation.declaredPair {
                guard let name = declared else { return nil }
                return relations.first { $0.database == relation.target && !isSame($0, relation) && columnName($0) == name }
            }
            let name = columnName(relation)
            if let mirror = relations.first(where: { other in
                other.database == relation.target && other.target == relation.database && !isSame(other, relation)
                    && other.declaredPair.flatMap({ $0 }) == name
            }) {
                return mirror
            }
            return relations.first { other in
                other.database == relation.target && other.target == relation.database && !isSame(other, relation)
                    && other.declaredPair == nil && Set(other.pairs.map { [$0[1], $0[0]] }) == relation.pairs
            }
        }
        var targetOfColumn: [[Int]: Int] = [:]
        for relation in relations {
            targetOfColumn[[relation.database, relation.column]] = relation.target
            var source = databases[relation.database]!
            let target = databases[relation.target]!
            var config: JSONValue = ["targetDatabaseId": .string(target.schema.pageId.databaseText), "limit": "none"]
            var line = "связь с «\(target.summary.title)»"
            if let pair = pairOf(relation) {
                config["pairedPropertyId"] = .string(databases[pair.database]!.properties[pair.column].id.databaseText)
                line += ", двусторонняя"
            }
            source.properties[relation.column].config = config
            source.summary.properties[relation.column] = "\(source.properties[relation.column].name) — \(line)"
            let propertyId = source.properties[relation.column].id
            let byRow = source.pendingRelations[relation.column] ?? [:]
            for position in source.rows.indices {
                guard let hexes = byRow[source.rows[position].pageIndex] else { continue }
                let targets = hexes.compactMap { plan.pageByNotionId[$0] }.filter { databaseOfRow[$0] == relation.target }
                if !targets.isEmpty { source.rows[position].relations.append((propertyId, targets.map { plan.pages[$0].id })) }
            }
            databases[relation.database] = source
        }

        // Сводки по схеме: связь — свойство этой базы, свойство цели — по названию в базе, куда ведёт связь.
        for (index, database) in databases.sorted(by: { $0.key < $1.key }) where !database.pendingRollups.isEmpty {
            var source = database
            for (column, rollup) in database.pendingRollups.sorted(by: { $0.key < $1.key }) {
                let relationName = source.properties[rollup.relationColumn].name
                guard let target = targetOfColumn[[index, rollup.relationColumn]], source.properties[rollup.relationColumn].kind == .relation else {
                    keepRollupValues(ofColumn: column, reason: "связь «\(relationName)» не перенесена", in: &source)
                    continue
                }
                guard let targetProperty = databases[target]?.properties.first(where: { $0.name == rollup.targetName }) else {
                    let targetTitle = databases[target]?.summary.title ?? ""
                    keepRollupValues(ofColumn: column, reason: "в базе «\(targetTitle)» нет столбца «\(rollup.targetName)»", in: &source)
                    continue
                }
                source.properties[column].config = ["relationPropertyId": .string(source.properties[rollup.relationColumn].id.databaseText),
                                                    "targetPropertyId": .string(targetProperty.id.databaseText),
                                                    "calculation": .string(rollup.calculation)]
            }
            databases[index] = source
        }
    }

    /// Сводку собрать не удалось: столбец остаётся значениями из выгрузки — угаданным типом, как у непереведённой формулы.
    private func keepRollupValues(ofColumn column: Int, reason: String, in database: inout PlannedDatabase) {
        guard let fallback = database.rollupFallbacks[column] else { return }
        let property = database.properties[column]
        database.properties[column].kind = fallback.kind.propertyKind
        database.properties[column].config = fallback.kind.config
        var optionIds: [String: UUID] = [:]
        if let names = fallback.kind.optionNames {
            var optionKey: FractionalSortKey?
            for (position, name) in names.enumerated() {
                optionKey = .between(optionKey, nil)
                let option = SelectOption(propertyId: property.id, name: name, color: OptionColor.allCases[position % OptionColor.allCases.count],
                                          sortKey: optionKey!)
                database.options.append(option)
                optionIds[name] = option.id
            }
        }
        for position in database.rows.indices {
            guard let text = fallback.texts[database.rows[position].pageIndex], !text.isEmpty,
                  let value = fallback.kind.value(text, optionIds: optionIds, timeZone: timeZone) else { continue }
            database.rows[position].cells.append((property.id, value))
        }
        database.summary.properties[column] = fallback.kind.reportLine(name: property.name)
        database.summary.notes.append("«\(property.name)» — сводка Notion не перенесена (\(reason)): значения из выгрузки")
    }

    /// Тип для значений сводки, которую не удалось собрать: угаданный, а то, что значениями не бывает, — текст.
    static func valueKind(_ guessed: ColumnKind) -> ColumnKind {
        switch guessed {
        case .title, .relation, .createdTime, .lastEditedTime, .rollup, .formula, .status: .text
        default: guessed
        }
    }

    // MARK: Вид и сопоставление

    /// Колонки вида: видимые — из CSV вида по порядку, остальные свойства — скрытые, по порядку полной таблицы.
    static func viewColumns(header: [String], viewFile: URL?, properties: [DatabaseProperty]) -> [JSONValue] {
        func column(_ index: Int, visible: Bool) -> JSONValue {
            var column: JSONValue = ["propertyId": .string(properties[index].id.databaseText), "isVisible": .bool(visible)]
            if index == 0 { column["width"] = 280 }
            return column
        }
        guard let viewFile, let text = try? String(contentsOf: viewFile, encoding: .utf8),
              let viewHeader = NotionCSV.rows(text).first?.map({ $0.trimmingCharacters(in: .whitespaces) }) else {
            return properties.indices.map { column($0, visible: true) }
        }
        var visible: [Int] = []
        for name in viewHeader {
            if let index = header.indices.first(where: { header[$0] == name && !visible.contains($0) }) { visible.append(index) }
        }
        if !visible.contains(0) { visible.insert(0, at: 0) }
        return visible.map { column($0, visible: true) } + properties.indices.filter { !visible.contains($0) }.map { column($0, visible: false) }
    }

    /// Название строки для сопоставления: у безымянной Notion пишет в файл «Untitled».
    static func titleKey(_ title: String) -> String {
        let key = title.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
        return key == "Untitled" ? "" : key
    }

    /// Сколько строк свойств файла совпало со значениями строки CSV.
    static func agreement(_ lines: [String: String], _ values: [String], _ header: [String]) -> Int {
        header.indices.dropFirst().reduce(0) { count, column in
            count + (lines[header[column]] == values[column] && !values[column].isEmpty ? 1 : 0)
        }
    }
}

extension NotionExportPlan {
    /// Строка CSV без своего файла (выгрузка без подстраниц): пустая страница с названием из CSV.
    mutating func appendSyntheticRow(title: String, database: Int) -> Int {
        let table = pages[database]
        var page = PlannedPage(key: table.key + "/\u{0}строка-\(pages.count)", file: table.file, isTable: false, title: title, parent: database)
        page.blocks = []
        pages.append(page)
        return pages.count - 1
    }
}

// MARK: - Строки свойств в `.md` строки

/// Под названием строки Notion пишет «Свойство: значение» (только непустые), потом пустую строку и тело.
/// Отрезаются только строки с названиями колонок базы; строка без «Название: » внутри блока — продолжение значения.
enum RowPropertyLines {
    static func cut(from text: String, names: Set<String>) -> (text: String, lines: [String: String]) {
        var lines = text.components(separatedBy: "\n")
        guard let titleIndex = lines.firstIndex(where: { $0.hasPrefix("# ") }) else { return (text, [:]) }
        var position = titleIndex + 1
        while position < lines.count, lines[position].trimmingCharacters(in: .whitespaces).isEmpty { position += 1 }
        let start = position
        var found: [String: String] = [:]
        var last: String?
        while position < lines.count, !lines[position].trimmingCharacters(in: .whitespaces).isEmpty {
            let line = lines[position]
            if let colon = line.range(of: ": "), names.contains(String(line[..<colon.lowerBound])) {
                let name = String(line[..<colon.lowerBound])
                found[name] = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
                last = name
            } else if let name = last {
                found[name, default: ""] += "\n" + line
            } else {
                return (text, [:])
            }
            position += 1
        }
        guard !found.isEmpty else { return (text, [:]) }
        lines.removeSubrange(start..<position)
        return (lines.joined(separator: "\n"), found)
    }
}

// MARK: - Связи в тексте

/// `Альфа (https://app.notion.com/p/<32 hex>?pvs=21), Бета (…)` и `Альфа (../Проекты/Альфа%20<32 hex>.md)`.
enum RelationText {
    private static let link = try! NSRegularExpression(pattern: #"\(([^()\s]*?([0-9a-fA-F]{32})[^()\s]*)\)"#)

    /// 32 hex целей по порядку; `nil` — текст не список ссылок.
    static func parse(_ text: String) -> [String]? {
        let ns = text as NSString
        var targets: [String] = []
        var location = 0
        for match in link.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: location, length: match.range.location - location))
            if !targets.isEmpty, !between.hasPrefix(", ") { return nil }
            let target = ns.substring(with: match.range(at: 1))
            guard target.hasPrefix("http") || target.hasSuffix(".md") else { return nil }
            targets.append(ns.substring(with: match.range(at: 2)).lowercased())
            location = NSMaxRange(match.range)
        }
        guard !targets.isEmpty, location == ns.length else { return nil }
        return targets
    }

    static func targets(_ text: String) -> [String] { parse(text) ?? [] }
}

// MARK: - Угадывание типа

/// Тип колонки по признакам contracts/sync-v4-and-export.md.
enum ColumnKind: Equatable {
    case title, text, checkbox, url, email, phone, date, createdTime, lastEditedTime, relation
    case number(format: String?)
    case uniqueId(prefix: String?)
    case options(multi: Bool, names: [String])
    // Только по схеме Notion: в выгрузке статус неотличим от выбора, а формула и сводка приходят значениями.
    case status(names: [String])
    case formula(stored: String)
    /// Настройки сводки (связь, свойство цели, вычисление) дописываются вторым проходом по связям.
    case rollup

    var propertyKind: PropertyKind {
        switch self {
        case .title: .title
        case .text: .text
        case .checkbox: .checkbox
        case .url: .url
        case .email: .email
        case .phone: .phone
        case .date: .date
        case .createdTime: .createdTime
        case .lastEditedTime: .lastEditedTime
        case .relation: .relation
        case .number: .number
        case .uniqueId: .uniqueId
        case .options(let multi, _): multi ? .multiSelect : .select
        case .status: .status
        case .formula: .formula
        case .rollup: .rollup
        }
    }

    var config: JSONValue {
        switch self {
        case .number(let format?): ["format": .string(format)]
        case .uniqueId(let prefix?): ["prefix": .string(prefix)]
        case .formula(let stored): ["expression": .string(stored)]
        default: .emptyObject
        }
    }

    /// Названия вариантов у выбора и статуса.
    var optionNames: [String]? {
        switch self {
        case .options(_, let names), .status(let names): names
        default: nil
        }
    }

    func reportLine(name: String) -> String {
        var title = PropertyKindTitles.title(propertyKind)
        if case .number(let format?) = self { title += format == "percent" ? " (процент)" : " (валюта)" }
        return "\(name) — \(title)"
    }

    /// Значение ячейки из текста колонки; `nil` — пусто.
    func value(_ text: String, optionIds: [String: UUID], timeZone: TimeZone) -> JSONValue? {
        switch self {
        case .title, .createdTime, .lastEditedTime, .relation, .formula, .rollup: return nil
        case .text: return ["runs": [], "string": .string(text)]
        case .checkbox: return .bool(text == "Yes")
        case .url, .email, .phone: return .string(text)
        case .number: return ColumnGuess.number(text).map { .number($0.value) }
        case .uniqueId: return ColumnGuess.uniqueId(text).map { .number(Double($0.number)) }
        case .date:
            guard let date = ColumnGuess.date(text, timeZone: timeZone) else { return nil }
            var value: JSONValue = ["start": .string(date.start), "hasTime": .bool(date.hasTime), "timeZone": .string(timeZone.identifier)]
            if let end = date.end { value["end"] = .string(end) }
            return value
        case .options(let multi, _):
            if multi {
                let ids = ColumnGuess.multiParts(text).compactMap { optionIds[$0] }
                return ids.isEmpty ? nil : .array(ids.map { .string($0.databaseText) })
            }
            return optionIds[text].map { .string($0.databaseText) }
        case .status:
            return optionIds[text].map { .string($0.databaseText) }
        }
    }
}

/// Названия типов в отчёте импорта.
enum PropertyKindTitles {
    static func title(_ kind: PropertyKind) -> String {
        switch kind {
        case .title: "название"
        case .text: "текст"
        case .number: "число"
        case .select: "выбор"
        case .multiSelect: "множественный выбор"
        case .status: "статус"
        case .date: "дата"
        case .checkbox: "флажок"
        case .url: "ссылка"
        case .email: "email"
        case .phone: "телефон"
        case .files: "файлы и медиа"
        case .createdTime: "создано"
        case .lastEditedTime: "изменено"
        case .relation: "связь"
        case .rollup: "сводка"
        case .formula: "формула"
        case .uniqueId: "ID"
        default: kind.rawValue
        }
    }
}

enum ColumnGuess {
    static let createdNames: Set<String> = ["created time", "created", "создано", "дата создания"]
    static let editedNames: Set<String> = ["last edited time", "last edited", "изменено", "дата изменения"]
    private static let currencies: [Character: String] = ["$": "dollar", "€": "euro", "£": "pound", "₽": "ruble", "¥": "yen", "₹": "rupee",
                                                          "₩": "won"]

    /// Первый подходящий целиком тип по порядку таблицы contracts; значения — непустые.
    static func kind(name: String, values: [String], timeZone: TimeZone) -> ColumnKind {
        guard !values.isEmpty else { return .text }
        if values.allSatisfy({ $0 == "Yes" || $0 == "No" }) { return .checkbox }
        let lowered = name.lowercased()
        // «ID» из чисел — раньше числа: иначе столбец ID Notion всегда стал бы числом.
        if lowered == "id", let ids = uniqueIds(values), ids.prefix == nil { return .uniqueId(prefix: nil) }
        if let format = numberFormat(values) { return .number(format: format) }
        let dates = values.map { date($0, timeZone: timeZone) }
        if dates.allSatisfy({ $0 != nil }) {
            let withTime = dates.allSatisfy { $0!.hasTime && $0!.end == nil }
            if withTime, createdNames.contains(lowered) { return .createdTime }
            if withTime, editedNames.contains(lowered) { return .lastEditedTime }
            return .date
        }
        if let ids = uniqueIds(values), let prefix = ids.prefix { return .uniqueId(prefix: prefix) }
        if values.allSatisfy(isURL) { return .url }
        if values.allSatisfy(isEmail) { return .email }
        if values.allSatisfy(isPhone) { return .phone }
        if values.allSatisfy({ RelationText.parse($0) != nil }) { return .relation }
        let parts = values.flatMap(multiParts)
        let distinct = orderedDistinct(parts)
        if values.contains(where: { $0.contains(", ") }), distinct.count <= 50, parts.count > distinct.count {
            return .options(multi: true, names: distinct)
        }
        let singles = orderedDistinct(values)
        if !values.contains(where: { $0.contains(",") }), singles.count <= 50, values.count >= 2 * singles.count {
            return .options(multi: false, names: singles)
        }
        return .text
    }

    static func multiParts(_ text: String) -> [String] {
        text.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func orderedDistinct(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: Число

    /// Число Notion: `1234.5`, `-3`, `50%`, `$5`, `5 €`. Значение процента — доля.
    static func number(_ text: String) -> (value: Double, percent: Bool, currency: Character?)? {
        var body = Substring(text)
        var currency: Character?
        if let first = body.first, currencies[first] != nil { currency = first; body = body.dropFirst() }
        else if let last = body.last, currencies[last] != nil { currency = last; body = body.dropLast() }
        body = body.drop { $0 == " " }
        while body.last == " " { body = body.dropLast() }
        let percent = body.last == "%"
        if percent { body = body.dropLast() }
        guard !body.isEmpty, currency == nil || !percent else { return nil }
        var digits = 0, dots = 0
        for (offset, character) in body.enumerated() {
            if character.isASCII, character.isNumber { digits += 1 }
            else if character == "." { dots += 1 }
            else if (character == "-" || character == "+"), offset == 0 { continue }
            else { return nil }
        }
        guard digits > 0, dots <= 1, let value = Double(body) else { return nil }
        return (percent ? value / 100 : value, percent, currency)
    }

    /// Формат числовой колонки: все — числа одного вида (все с `%`, все с одним знаком валюты или все простые).
    private static func numberFormat(_ values: [String]) -> String?? {
        var kind: String??
        for value in values {
            guard let parsed = number(value) else { return nil }
            let this: String? = parsed.percent ? "percent" : parsed.currency.flatMap { currencies[$0] }
            if let kind, kind != this { return nil }
            kind = .some(this)
        }
        return kind
    }

    // MARK: ID

    /// `1…N` или `ПРЕФИКС-N` с одним префиксом, все номера разные.
    static func uniqueId(_ text: String) -> (prefix: String?, number: Int)? {
        if let number = Int(text), number > 0 { return (nil, number) }
        guard let dash = text.lastIndex(of: "-"), let number = Int(text[text.index(after: dash)...]), number > 0 else { return nil }
        let prefix = String(text[..<dash])
        guard !prefix.isEmpty, !prefix.contains(" ") else { return nil }
        return (prefix, number)
    }

    private static func uniqueIds(_ values: [String]) -> (prefix: String?, numbers: [Int])? {
        let parsed = values.map(uniqueId)
        guard parsed.allSatisfy({ $0 != nil }), let first = parsed.first! else { return nil }
        guard parsed.allSatisfy({ $0!.prefix == first.prefix }) else { return nil }
        let numbers = parsed.map { $0!.number }
        return Set(numbers).count == numbers.count ? (first.prefix, numbers) : nil
    }

    // MARK: Ссылка, почта, телефон

    static func isURL(_ text: String) -> Bool {
        (text.hasPrefix("http://") || text.hasPrefix("https://")) && !text.contains(" ") && text.count > 8
    }

    static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !text.contains(" ") else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    static func isPhone(_ text: String) -> Bool {
        var digits = 0
        for character in text {
            if character.isASCII, character.isNumber { digits += 1 }
            else if !"+()- ".contains(character) { return false }
        }
        return digits >= 7
    }

    // MARK: Дата

    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                                 "November", "December"]

    /// Дата Notion (`October 21, 2026`, `October 21, 2026 3:15 PM`, `… → …`) или ISO (`2026-10-21`, `2026-10-21T15:15`):
    /// `start` и `end` — как в значении ячейки даты.
    static func date(_ text: String, timeZone: TimeZone) -> (start: String, end: String?, hasTime: Bool)? {
        guard let first = text.first, first.isLetter || first.isNumber else { return nil }
        let parts = text.components(separatedBy: " → ")
        guard parts.count <= 2, let start = one(parts[0]) else { return nil }
        if parts.count == 2 {
            guard let end = one(parts[1]) else { return nil }
            return (start.text, end.text, start.hasTime || end.hasTime)
        }
        return (start.text, nil, start.hasTime)
    }

    private static func one(_ text: String) -> (text: String, hasTime: Bool)? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let first = text.first, first.isNumber { return iso(text) }
        let words = text.split(separator: " ")
        guard words.count == 3 || words.count == 4 || words.count == 5, let month = months.firstIndex(of: String(words[0])),
              words[1].hasSuffix(","), let day = Int(words[1].dropLast()), (1...31).contains(day),
              let year = Int(words[2]), (1...9999).contains(year) else { return nil }
        let date = String(format: "%04d-%02d-%02d", year, month + 1, day)
        guard words.count > 3 else { return (date, false) }
        let clock = words[3].split(separator: ":")
        guard clock.count == 2, var hour = Int(clock[0]), let minute = Int(clock[1]), clock[1].count == 2, (0...59).contains(minute) else { return nil }
        if words.count == 5 {
            guard (1...12).contains(hour), words[4] == "AM" || words[4] == "PM" else { return nil }
            hour = hour % 12 + (words[4] == "PM" ? 12 : 0)
        } else {
            guard (0...23).contains(hour) else { return nil }
        }
        return (date + String(format: "T%02d:%02d", hour, minute), true)
    }

    private static func iso(_ text: String) -> (text: String, hasTime: Bool)? {
        let bytes = Array(text.utf8)
        func digits(_ range: Range<Int>) -> Bool { range.upperBound <= bytes.count && range.allSatisfy { bytes[$0] >= 48 && bytes[$0] <= 57 } }
        guard digits(0..<4), bytes.count >= 10, bytes[4] == 45, digits(5..<7), bytes[7] == 45, digits(8..<10) else { return nil }
        if bytes.count == 10 { return (text, false) }
        guard bytes.count == 16, bytes[10] == 84, digits(11..<13), bytes[13] == 58, digits(14..<16) else { return nil }
        return (text, true)
    }
}
