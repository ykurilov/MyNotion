import Foundation
import GRDB
import NotesCore

/// Связи и сводки (US4, research R7, R8, contracts/property-types.md): новая связь с другой базой или этой же, лимит,
/// ответное свойство, связать и снять строку, новая строка цели из окна связи, настройка сводки. Каждая правка — одна
/// транзакция и один шаг ⌘Z. Связь — своя запись `db_relation_link`: снятие — `isPresent = нет`, запись остаётся.
extension DatabaseOperations {
    // MARK: Свойство-связь

    /// «Новая связь» (`notion-relation-new-settings.png`): связь с базой `target` (в том числе этой же), лимит;
    /// `relatedName` — включено «Ответное свойство»: в базе-цели появляется пара с этим именем. ⌘Z убирает оба свойства.
    @discardableResult
    public func addRelation(to databaseId: UUID, name: String, target: UUID, limit: RelationLimit = .none,
                            relatedName: String? = nil) throws -> DatabaseProperty {
        try perform("Новая связь") { transaction in
            guard try transaction.isDatabase(target) else { throw NotesStoreError.invalidRecord("связь ведёт не на базу") }
            let last = try transaction.properties(ofDatabase: databaseId, includingDeleted: true).map(\.sortKey).max()
            var property = try transaction.saveProperty(DatabaseProperty(
                databaseId: databaseId, name: name, kind: .relation,
                config: ["targetDatabaseId": .string(target.databaseText), "limit": .string(limit.rawValue)], sortKey: .between(last, nil)))
            var created = [property.id]
            if let relatedName {
                let paired = try Self.writePairedProperty(for: property, name: relatedName, transaction)
                property.config["pairedPropertyId"] = .string(paired.id.databaseText)
                property = try transaction.saveProperty(property)
                created.append(paired.id)
            }
            return (property, { try $0.setPropertiesDeleted(created, true, actionName: "Новая связь") })
        }
    }

    /// Лимит связи; прежние связи остаются, следующая правка его соблюдает (как Notion).
    public func setRelationLimit(_ propertyId: UUID, _ limit: RelationLimit) throws {
        var config = try currentProperty(propertyId).config
        config["limit"] = .string(limit.rawValue)
        try setPropertyConfig(propertyId, config)
    }

    /// «Ответное свойство» в базе-цели: включить — вернуть прежнюю пару или завести новую (связи сразу видны на той
    /// стороне); выключить — пара уходит в «Удалённые свойства», связи остаются. `name` — имя пары.
    public func setRelatedProperty(of propertyId: UUID, enabled: Bool, name: String? = nil) throws {
        try performChange("Ответное свойство") { transaction in
            var property = try Self.requireProperty(propertyId, transaction)
            guard property.kind == .relation else { throw NotesStoreError.invalidRecord("это не связь") }
            let known = try property.pairedRelation.flatMap { try transaction.property($0) }.flatMap { $0.config[Self.erasedKey] == nil ? $0 : nil }
            if enabled {
                if var paired = known {
                    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard paired.deletedAt != nil || (!trimmed.isEmpty && trimmed != paired.name) else { return nil }
                    paired.deletedAt = nil
                    if !trimmed.isEmpty { paired.name = trimmed }
                    try transaction.saveProperty(paired)
                } else {
                    let before = RelationLinks.storage(of: property)
                    let paired = try Self.writePairedProperty(for: property, name: name ?? "", transaction)
                    property.config["pairedPropertyId"] = .string(paired.id.databaseText)
                    property = try transaction.saveProperty(property)
                    try Self.moveLinks(from: before, to: RelationLinks.storage(of: property), transaction)
                }
                return { try $0.setRelatedProperty(of: propertyId, enabled: false) }
            }
            guard var paired = known, paired.deletedAt == nil else { return nil }
            paired.deletedAt = Date()
            try transaction.saveProperty(paired)
            return { try $0.setRelatedProperty(of: propertyId, enabled: true) }
        }
    }

    // MARK: Связать и снять

    /// Связать строку со строкой цели (окно связи, щелчок по строке). Лимит «1 страница» (своей стороны и ответной)
    /// снимает прежнюю связь той же правкой. Уже связанные — без шага.
    public func linkRow(_ rowId: UUID, through propertyId: UUID, to targetRowId: UUID) throws {
        try performChange("Связь") { transaction in
            let property = try Self.requireRelation(propertyId, transaction)
            let states = try Self.linkStates(rowId, property, targetRowId, transaction)
            guard !states.isEmpty else { return nil }
            let previous = try Self.writeLinks(states, transaction)
            return { try $0.restoreLinks(previous, actionName: "Связь") }
        }
    }

    /// Снять связь («−» у выбранной строки окна связи).
    public func unlinkRow(_ rowId: UUID, through propertyId: UUID, from targetRowId: UUID) throws {
        try performChange("Связь") { transaction in
            let property = try Self.requireRelation(propertyId, transaction)
            guard var link = try transaction.relationLink(RelationLinks.linkId(rowId, through: property, to: targetRowId)), link.isPresent
            else { return nil }
            link.isPresent = false
            let previous = try Self.writeLinks([link], transaction)
            return { try $0.restoreLinks(previous, actionName: "Связь") }
        }
    }

    /// «Найти или создать страницу…» → «+ Новая страница»: строка `title` в базе-цели и связь с ней — один шаг ⌘Z
    /// (отмена уносит строку в корзину и возвращает прежние связи).
    @discardableResult
    public func createLinkedRow(for rowId: UUID, through propertyId: UUID, title: String) throws -> UUID {
        try perform("Новая строка") { transaction in
            let property = try Self.requireRelation(propertyId, transaction)
            guard let target = property.relationTarget else { throw NotesStoreError.invalidRecord("связь не настроена") }
            let created = try Self.writeRow(in: target, viewId: nil, placement: .bottom, title: title, transaction)
            let previous = try Self.writeLinks(try Self.linkStates(rowId, property, created, transaction), transaction)
            return (created, { try $0.withdrawLinkedRow(created, links: previous) })
        }
    }

    // MARK: Сводка

    /// Настройка сводки: «Связь», «Свойство» цели и «Вычислить» — одним шагом ⌘Z; итоги всех строк — в фоне.
    public func setRollup(_ propertyId: UUID, relation: UUID?, target: UUID?, calculation: Calculation) throws {
        var config = try currentProperty(propertyId).config
        config["relationPropertyId"] = relation.map { .string($0.databaseText) }
        config["targetPropertyId"] = target.map { .string($0.databaseText) }
        config["calculation"] = .string(calculation.rawValue)
        try setPropertyConfig(propertyId, config)
    }

    // MARK: Внутреннее

    private func currentProperty(_ propertyId: UUID) throws -> DatabaseProperty {
        guard let property = try store.database.dbWriter.read({ db in
            try Row.fetchOne(db, sql: "SELECT * FROM db_property WHERE id = ?", arguments: [propertyId.databaseText]).map(DatabaseProperty.init(row:))
        }) else { throw NotesStoreError.invalidRecord("свойства нет") }
        return property
    }

    /// Несколько свойств в «Удалённые свойства» или обратно одним шагом (новая связь с парой).
    func setPropertiesDeleted(_ ids: [UUID], _ isDeleted: Bool, actionName: String) throws {
        try perform(actionName) { transaction in
            for id in ids {
                var property = try Self.requireProperty(id, transaction)
                guard (property.deletedAt != nil) != isDeleted else { continue }
                property.deletedAt = isDeleted ? Date() : nil
                try transaction.saveProperty(property)
            }
            return ((), { try $0.setPropertiesDeleted(ids, !isDeleted, actionName: actionName) })
        }
    }

    /// Вернуть связи к записанному состоянию; шаг повтора — их состояние до возврата.
    func restoreLinks(_ links: [RelationLink], actionName: String) throws {
        try perform(actionName) { transaction in
            let current = try Self.writeLinks(links, transaction)
            return ((), { try $0.restoreLinks(current, actionName: actionName) })
        }
    }

    private func withdrawLinkedRow(_ rowId: UUID, links: [RelationLink]) throws {
        try perform("Новая строка") { transaction in
            let current = try Self.writeLinks(links, transaction)
            if var page = try transaction.page(rowId), page.trashedAt == nil {
                page.trashedAt = Date()
                try transaction.updatePage(page)
            }
            return ((), { try $0.reinstateLinkedRow(rowId, links: current) })
        }
    }

    private func reinstateLinkedRow(_ rowId: UUID, links: [RelationLink]) throws {
        try perform("Новая строка") { transaction in
            guard var page = try transaction.page(rowId) else { throw NotesStoreError.pageNotFound(rowId) }
            page.trashedAt = nil
            try transaction.updatePage(page)
            let current = try Self.writeLinks(links, transaction)
            return ((), { try $0.withdrawLinkedRow(rowId, links: current) })
        }
    }

    nonisolated static func requireRelation(_ id: UUID, _ transaction: NotesTransaction) throws -> DatabaseProperty {
        let property = try requireProperty(id, transaction)
        guard property.kind == .relation else { throw NotesStoreError.invalidRecord("это не связь") }
        return property
    }

    /// Ответное свойство в базе-цели. Его id больше id связи: связи пары остаются у неё (хранятся у меньшего id).
    nonisolated static func writePairedProperty(for property: DatabaseProperty, name: String, _ transaction: NotesTransaction) throws -> DatabaseProperty {
        guard let target = property.relationTarget else { throw NotesStoreError.invalidRecord("связь не настроена") }
        var id = UUID.timeOrdered()
        while !(property.id.uuidString < id.uuidString) { id = UUID.timeOrdered() }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceTitle = try transaction.page(property.databaseId)?.title ?? ""
        let last = try transaction.properties(ofDatabase: target, includingDeleted: true).map(\.sortKey).max()
        return try transaction.saveProperty(DatabaseProperty(
            id: id, databaseId: target, name: trimmed.isEmpty ? (sourceTitle.isEmpty ? "Связь" : sourceTitle) : trimmed, kind: .relation,
            config: ["targetDatabaseId": .string(property.databaseId.databaseText), "limit": .string(RelationLimit.none.rawValue),
                     "pairedPropertyId": .string(property.id.databaseText)],
            sortKey: .between(last, nil)))
    }

    /// Связи переехали к другому свойству хранения (новая пара вместо стёртой): каждая — новой записью, прежняя снята.
    nonisolated static func moveLinks(from old: (propertyId: UUID, reversed: Bool), to new: (propertyId: UUID, reversed: Bool),
                                      _ transaction: NotesTransaction) throws {
        guard old.propertyId != new.propertyId else { return }
        let links = try Row.fetchAll(transaction.database, sql: "SELECT * FROM db_relation_link WHERE propertyId = ? AND isPresent = 1",
                                     arguments: [old.propertyId.databaseText]).map(RelationLink.init(row:))
        for var link in links {
            let (row, target) = old.reversed ? (link.targetRowId, link.rowId) : (link.rowId, link.targetRowId)
            let (newRow, newTarget) = new.reversed ? (target, row) : (row, target)
            try transaction.saveRelationLink(RelationLink(propertyId: new.propertyId, rowId: newRow, targetRowId: newTarget, sortKey: link.sortKey))
            link.isPresent = false
            try transaction.saveRelationLink(link)
        }
    }

    /// Связи ячейки строки (по порядку), в записях хранения.
    nonisolated static func cellLinks(_ rowId: UUID, _ property: DatabaseProperty, _ transaction: NotesTransaction) throws -> [RelationLink] {
        let storage = RelationLinks.storage(of: property)
        let column = storage.reversed ? "targetRowId" : "rowId"
        return try Row.fetchAll(transaction.database, sql: """
            SELECT * FROM db_relation_link WHERE propertyId = ? AND \(column) = ? AND isPresent = 1 ORDER BY sortKey, id
            """, arguments: [storage.propertyId.databaseText, rowId.databaseText]).map(RelationLink.init(row:))
    }

    /// Что записать, чтобы связать `rowId` с `targetRowId`: новая связь в конце ячейки и снятые лимитом. Пусто — уже связаны.
    nonisolated static func linkStates(_ rowId: UUID, _ property: DatabaseProperty, _ targetRowId: UUID,
                                       _ transaction: NotesTransaction) throws -> [RelationLink] {
        let id = RelationLinks.linkId(rowId, through: property, to: targetRowId)
        if try transaction.relationLink(id)?.isPresent == true { return [] }
        let own = try cellLinks(rowId, property, transaction)
        var states: [RelationLink] = []
        func remove(_ links: [RelationLink]) {
            for var link in links where link.id != id {
                link.isPresent = false
                states.append(link)
            }
        }
        if property.relationLimit == .one { remove(own) }
        if let pairedId = property.pairedRelation, let paired = try transaction.property(pairedId), paired.deletedAt == nil,
           paired.relationLimit == .one {
            remove(try cellLinks(targetRowId, paired, transaction))
        }
        // Место — после последней связи и этой строки, и строки цели: порядок в ячейках обеих сторон — по времени связи.
        let storage = RelationLinks.storage(of: property)
        let targetColumn = storage.reversed ? "rowId" : "targetRowId"
        let targetLast = try String.fetchOne(transaction.database, sql: """
            SELECT MAX(sortKey) FROM db_relation_link WHERE propertyId = ? AND \(targetColumn) = ? AND isPresent = 1
            """, arguments: [storage.propertyId.databaseText, targetRowId.databaseText]).flatMap(FractionalSortKey.init(rawValue:))
        let sortKey = FractionalSortKey.between([own.last?.sortKey, targetLast].compactMap { $0 }.max(), nil)
        states.append(storage.reversed ? RelationLink(propertyId: storage.propertyId, rowId: targetRowId, targetRowId: rowId, sortKey: sortKey)
                                       : RelationLink(propertyId: storage.propertyId, rowId: rowId, targetRowId: targetRowId, sortKey: sortKey))
        return states
    }

    /// Записать связи (наличие и место); возвращает их прежнее состояние для шага отмены (новые — снятыми).
    nonisolated static func writeLinks(_ links: [RelationLink], _ transaction: NotesTransaction) throws -> [RelationLink] {
        var previous: [RelationLink] = []
        for link in links {
            if let stored = try transaction.relationLink(link.id) {
                previous.append(stored)
            } else {
                guard link.isPresent else { continue }
                previous.append(RelationLink(propertyId: link.propertyId, rowId: link.rowId, targetRowId: link.targetRowId, sortKey: link.sortKey,
                                             isPresent: false))
            }
            var saved = link
            if let stored = try transaction.relationLink(link.id) { saved.fieldClocks = stored.fieldClocks }
            try transaction.saveRelationLink(saved)
        }
        return previous
    }
}
