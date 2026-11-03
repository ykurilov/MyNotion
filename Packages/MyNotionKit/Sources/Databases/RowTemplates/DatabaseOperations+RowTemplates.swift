import Foundation
import GRDB
import NotesCore

/// Шаблоны строк (spec US6, research R13, contracts/database-ui.md, «Создать ▾»): новый шаблон, по умолчанию,
/// дублировать, удалить; новая строка по шаблону и шаблон на пустой странице строки. Строка по шаблону — копия его
/// страницы (`PageBranchCopier` 003: иконка, обложка, вид, блоки, подстраницы), значения ячеек и связи; «Сегодня» и
/// «Сейчас» у дат и «@сегодня» в теле — момент создания строки. Каждая правка — одна транзакция и один шаг ⌘Z.
extension DatabaseOperations {
    // MARK: Шаблоны базы

    /// «+ Новый шаблон»: пустой шаблон последним; номер ID ему не выдаётся. ⌘Z — в корзину.
    @discardableResult
    public func addRowTemplate(to databaseId: UUID, title: String = "") throws -> UUID {
        try perform("Новый шаблон") { transaction in
            guard try transaction.database(databaseId) != nil else { throw NotesStoreError.invalidRecord("это не база") }
            var page = try transaction.createPage(title: title, parentId: databaseId)
            page.isTemplate = true
            try transaction.updatePage(page)
            return (page.id, { try $0.trashRowTemplate(page.id) })
        }
    }

    /// «Сделать по умолчанию» (`nil` — «Пустая»): по нему «Создать» и «+ Новая строка» делают строки.
    public func setDefaultRowTemplate(_ templateId: UUID?, of databaseId: UUID) throws {
        try performChange("Шаблон по умолчанию") { transaction in
            guard var schema = try transaction.database(databaseId) else { throw NotesStoreError.invalidRecord("это не база") }
            if let templateId { _ = try RowTemplates.requireTemplate(templateId, of: databaseId, transaction) }
            let previous = try RowTemplates.defaultTemplate(of: databaseId, transaction)
            guard previous != templateId else { return nil }
            schema.defaultTemplateId = templateId
            try transaction.saveDatabase(schema)
            return { try $0.setDefaultRowTemplate(previous, of: databaseId) }
        }
    }

    /// «Дублировать»: копия-шаблон сразу за оригиналом, «Имя (1)», со своими значениями, связями и телом; даты
    /// остаются относительными.
    @discardableResult
    public func duplicateRowTemplate(_ templateId: UUID) throws -> UUID {
        try perform("Дублирование шаблона") { transaction in
            let template = try RowTemplates.requireTemplate(templateId, of: nil, transaction)
            guard let databaseId = template.parentId else { throw NotesStoreError.invalidRecord("шаблон без базы") }
            let next = try String.fetchOne(transaction.database, sql: """
                SELECT MIN(sortKey) FROM page WHERE parentId = ? AND sortKey > ? AND trashedAt IS NULL
                """, arguments: [databaseId.databaseText, template.sortKey.rawValue]).flatMap(FractionalSortKey.init(rawValue:))
            let copyId = try PageBranchCopier.copy(templateId, in: transaction, title: try Self.copyTitle(of: template, in: databaseId, transaction),
                                                   parentId: databaseId, sortKey: Self.key(between: template.sortKey, next),
                                                   resolvesTemplateDates: false, rootIsTemplate: true).rootId
            _ = try Self.copyTemplateValues(from: templateId, to: copyId, in: databaseId, resolvingDatesAt: nil, transaction)
            return (copyId, { try $0.trashRowTemplate(copyId) })
        }
    }

    /// «Удалить»: шаблон в корзину; был по умолчанию — по умолчанию снова «Пустая». ⌘Z возвращает и метку.
    public func trashRowTemplate(_ templateId: UUID) throws {
        try perform("Удаление шаблона") { transaction in
            var template = try RowTemplates.requireTemplate(templateId, of: nil, transaction)
            guard let databaseId = template.parentId else { throw NotesStoreError.invalidRecord("шаблон без базы") }
            let wasDefault = try RowTemplates.defaultTemplate(of: databaseId, transaction) == templateId
            if wasDefault, var schema = try transaction.database(databaseId) {
                schema.defaultTemplateId = nil
                try transaction.saveDatabase(schema)
            }
            template.trashedAt = Date()
            try transaction.updatePage(template)
            return ((), { try $0.restoreRowTemplate(templateId, asDefault: wasDefault) })
        }
    }

    private func restoreRowTemplate(_ templateId: UUID, asDefault: Bool) throws {
        try perform("Удаление шаблона") { transaction in
            guard var template = try transaction.page(templateId), let databaseId = template.parentId else { throw NotesStoreError.pageNotFound(templateId) }
            template.trashedAt = nil
            try transaction.updatePage(template)
            if asDefault, var schema = try transaction.database(databaseId) {
                schema.defaultTemplateId = templateId
                try transaction.saveDatabase(schema)
            }
            return ((), { try $0.trashRowTemplate(templateId) })
        }
    }

    // MARK: Строка по шаблону

    /// Новая строка по шаблону («Создать ▾», «Создать», «+ Новая строка»); значения вида (`defaults`) — поверх шаблона.
    /// ⌘Z — строка в корзину.
    @discardableResult
    public func addRow(to databaseId: UUID, in viewId: UUID?, at placement: NewRowPlacement = .bottom, defaults: NewRowDefaults,
                       template: RowTemplateChoice = .databaseDefault, now: Date = Date()) throws -> UUID {
        try perform("Новая строка") { transaction in
            let templateId: UUID? = switch template {
            case .empty: nil
            case .databaseDefault: try RowTemplates.defaultTemplate(of: databaseId, transaction)
            case .template(let id): try RowTemplates.requireTemplate(id, of: databaseId, transaction).id
            }
            let rowId = try Self.writeRow(in: databaseId, viewId: viewId, placement: placement, title: defaults.title ?? "", transaction)
            if let templateId {
                _ = try Self.fill(rowId, fromTemplate: templateId, in: databaseId, title: defaults.title, now: now, transaction)
            }
            for (propertyId, value) in defaults.cells.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                try transaction.setCell(rowId: rowId, propertyId: propertyId, value: value)
            }
            return (rowId, { try $0.setRowsTrashed([rowId], true) })
        }
    }

    /// Шаблон на пустой странице строки: тело, иконка, обложка, значения и связи; название строки остаётся, если оно есть.
    /// ⌘Z возвращает строку как была.
    public func applyRowTemplate(_ templateId: UUID, toRow rowId: UUID, now: Date = Date()) throws {
        try perform("Шаблон строки") { transaction in
            guard let row = try transaction.page(rowId), let databaseId = row.parentId else { throw NotesStoreError.pageNotFound(rowId) }
            let blocks = try transaction.blocks(ofPage: rowId)
            let hasSubpages = try transaction.allPages().contains { $0.parentId == rowId && $0.trashedAt == nil }
            guard !hasSubpages, blocks.allSatisfy({ $0.kind == .paragraph && $0.containerId == nil && $0.text.string.isEmpty }) else {
                throw NotesStoreError.invalidPage("шаблон кладут только на пустую страницу")
            }
            let cells = Dictionary(uniqueKeysWithValues: try transaction.cells(ofRow: rowId).map { ($0.propertyId, $0.value) })
            let filled = try Self.fill(rowId, fromTemplate: templateId, in: databaseId, title: row.title.isEmpty ? nil : row.title,
                                       now: now, transaction)
            let before = AppliedTemplate(row: row, blocks: blocks, cells: filled.properties.map { ($0, cells[$0] ?? nil) },
                                         links: filled.links, subpageIds: filled.subpageIds)
            return ((), { try $0.unapplyRowTemplate(templateId, before) })
        }
    }

    /// Строка до шаблона: поля страницы, пустые блоки, значения перезаписанных ячеек, связи; копии подстраниц шаблона.
    struct AppliedTemplate {
        let row: Page
        let blocks: [Block]
        let cells: [(UUID, JSONValue?)]
        let links: [RelationLink]
        let subpageIds: [UUID]
    }

    private func unapplyRowTemplate(_ templateId: UUID, _ before: AppliedTemplate) throws {
        try perform("Шаблон строки") { transaction in
            let rowId = before.row.id
            for id in before.subpageIds where try transaction.page(id) != nil { try transaction.erasePage(id) }
            for block in try transaction.blocks(ofPage: rowId) { try transaction.deleteBlock(block.id) }
            guard var page = try transaction.page(rowId) else { throw NotesStoreError.pageNotFound(rowId) }
            page.title = before.row.title
            page.icon = before.row.icon
            page.cover = before.row.cover
            page.isFullWidth = before.row.isFullWidth
            page.isSmallText = before.row.isSmallText
            try transaction.updatePage(page)
            for block in before.blocks { try transaction.insertBlock(block) }
            for (propertyId, value) in before.cells { try transaction.setCell(rowId: rowId, propertyId: propertyId, value: value) }
            _ = try Self.writeLinks(before.links, transaction)
            return ((), { try $0.applyRowTemplate(templateId, toRow: rowId) })
        }
    }

    // MARK: Внутреннее

    /// Что записала копия шаблона в строку: ячейки, прежние связи (для отмены), копии подстраниц.
    struct FilledRow {
        let properties: [UUID]
        let links: [RelationLink]
        let subpageIds: [UUID]
    }

    /// Положить шаблон в строку `rowId`: её блоки заменяются телом шаблона, поля страницы — его полями (`title` —
    /// своё название вместо названия шаблона), даты шаблона — момент `now`.
    nonisolated static func fill(_ rowId: UUID, fromTemplate templateId: UUID, in databaseId: UUID, title: String?, now: Date,
                                 _ transaction: NotesTransaction) throws -> FilledRow {
        let template = try RowTemplates.requireTemplate(templateId, of: databaseId, transaction)
        guard let row = try transaction.page(rowId) else { throw NotesStoreError.pageNotFound(rowId) }
        for block in try transaction.blocks(ofPage: rowId) { try transaction.deleteBlock(block.id) }
        let copied = try PageBranchCopier.copy(templateId, in: transaction, title: title ?? template.title, parentId: databaseId,
                                               sortKey: row.sortKey, now: now, resolvesTemplateDates: true, rootIsTemplate: false,
                                               fillingPage: rowId)
        let values = try copyTemplateValues(from: templateId, to: rowId, in: databaseId, resolvingDatesAt: now, transaction)
        return FilledRow(properties: values.properties, links: values.links,
                         subpageIds: copied.pageIds.filter { $0.key != templateId }.map(\.value))
    }

    /// Значения ячеек (кроме номера ID) и связи шаблона — в строку. `resolvingDatesAt` — «Сегодня» и «Сейчас» у дат
    /// становятся этим моментом; `nil` — остаются относительными (копия шаблона).
    nonisolated static func copyTemplateValues(from templateId: UUID, to rowId: UUID, in databaseId: UUID, resolvingDatesAt now: Date?,
                                               _ transaction: NotesTransaction) throws -> (properties: [UUID], links: [RelationLink]) {
        let uniqueId = try UniqueIds.property(ofDatabase: databaseId, in: transaction)?.id
        var properties: [UUID] = []
        for cell in try transaction.cells(ofRow: templateId) where cell.propertyId != uniqueId {
            guard let value = cell.value else { continue }
            try transaction.setCell(rowId: rowId, propertyId: cell.propertyId, value: now.map { resolvedTemplateDate(value, at: $0) } ?? value)
            properties.append(cell.propertyId)
        }
        var links: [RelationLink] = []
        for relation in try transaction.properties(ofDatabase: databaseId) where relation.kind == .relation {
            for target in try RelationLinks.targets(of: [templateId], through: relation, in: transaction.database)[templateId] ?? [] {
                links += try writeLinks(try linkStates(rowId, relation, target.id, transaction), transaction)
            }
        }
        return (properties, links)
    }

    /// Дата шаблона `{relative: "today" | "now"}` — день (или день и время) момента `now` в поясе даты.
    nonisolated static func resolvedTemplateDate(_ value: JSONValue, at now: Date) -> JSONValue {
        guard case .object(var fields) = value, case .string(let relative)? = fields["relative"] else { return value }
        let includesTime = relative == "now"
        var calendar = Calendar(identifier: .gregorian)
        if case .string(let zone)? = fields["timeZone"], let timeZone = TimeZone(identifier: zone) { calendar.timeZone = timeZone }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        fields["start"] = .string(includesTime ? day + String(format: "T%02d:%02d", parts.hour ?? 0, parts.minute ?? 0) : day)
        fields["hasTime"] = .bool(includesTime)
        fields["relative"] = nil
        fields["end"] = nil
        return .object(fields)
    }
}
