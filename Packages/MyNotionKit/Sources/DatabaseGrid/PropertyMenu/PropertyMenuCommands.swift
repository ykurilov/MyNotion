import Databases
import Foundation
import NotesCore

/// Что делать после выбора пункта меню колонки: правка уже сделана или пора открыть окно пункта.
public enum PropertyMenuOutcome: Sendable, Hashable {
    case done
    case openEditPanel
    case openTypeList
    case confirmDelete
    /// Новая колонка («Вставить слева / справа»): под ней окно имени и типа, как у Notion.
    case configureNew(UUID)
    /// «Фильтр» (US3): плашка свойства добавлена — открыть её окно.
    case openFilter(FilterPath)
    /// «Сортировка ›» и «Посчитать ›» (US3): подменю у пункта.
    case openSortMenu
    case openCalculateMenu
}

/// Пункты US1 меню колонки и их действия над базой (contracts/database-ui.md, «Меню колонки»): окна рисует
/// `PropertyMenuPresenter`, здесь — что показывать и что записать. Пункты US3 (фильтр, сортировка, группировка, итог,
/// скрыть, перенос) добавит своя история — без обработчика реестр их не показывает.
@MainActor
public struct PropertyMenuCommands {
    public let store: NotesStore
    public let operations: DatabaseOperations
    public let databaseId: UUID
    public var viewId: UUID?

    public init(store: NotesStore, operations: DatabaseOperations, databaseId: UUID, viewId: UUID?) {
        self.store = store
        self.operations = operations
        self.databaseId = databaseId
        self.viewId = viewId
    }

    /// Места с обработчиком US1; «Вставить слева / справа» ставят колонку в вид — без вида их нет.
    public var handledSlots: Set<PropertyMenuSlot> {
        var slots: Set<PropertyMenuSlot> = [.editProperty, .changeType, .duplicate, .delete]
        if viewId != nil { slots.formUnion([.insertLeft, .insertRight]) }
        // Пункты вида (US3) — только у колонки вида.
        if viewId != nil { slots.formUnion([.filter, .sort, .group, .calculate, .hide, .wrap]) }
        return slots
    }

    /// Разделы панели «Изменить свойство» US1; настройки типа — когда у типа есть окно (`PropertyTypeSettings`).
    public static let panelSlots: Set<PropertySettingsSlot> = [.name, .type, .duplicate, .delete]

    /// Разделы панели у этого окна: «Переносить текст» пишется в вид, без вида его нет.
    public var panelSlots: Set<PropertySettingsSlot> {
        viewId == nil ? Self.panelSlots : Self.panelSlots.union([.wrapText])
    }

    public func wraps(_ property: DatabaseProperty) throws -> Bool {
        guard let viewId, let view = try store.write({ try $0.view(viewId) }) else { return false }
        return view.wraps(property.id)
    }

    public func setWrap(_ property: DatabaseProperty, _ wraps: Bool) throws {
        guard let viewId else { return }
        try operations.setWrap(property.id, wraps, in: viewId)
    }

    public func entries(for property: DatabaseProperty) -> [PropertyMenu.Entry] {
        let wraps = (viewId.flatMap { id in try? store.write { try $0.view(id) } })?.wraps(property.id) ?? false
        return PropertyMenu.entries(items: PropertyMenuItem.all, property: property, handled: handledSlots).map { entry in
            // «Переносить текст» / «Не переносить» — по состоянию колонки (Notion «Wrap / Unwrap content»).
            entry.slot == .wrap && wraps ? PropertyMenu.Entry(slot: .wrap, title: "Не переносить текст") : entry
        }
    }

    /// Выбор пункта: вставка и копия пишутся сразу, остальные пункты открывают своё окно.
    public func perform(_ slot: PropertyMenuSlot, on property: DatabaseProperty) throws -> PropertyMenuOutcome {
        switch slot {
        case .editProperty: return .openEditPanel
        case .changeType: return .openTypeList
        case .delete: return .confirmDelete
        case .insertLeft, .insertRight:
            guard let viewId else { return .done }
            let inserted = try operations.insertProperty(beside: property.id, side: slot == .insertLeft ? .left : .right, in: viewId)
            return .configureNew(inserted.id)
        case .duplicate:
            try operations.duplicateProperty(property.id, in: viewId)
            return .done
        case .filter:
            guard let viewId else { return .done }
            return .openFilter(try operations.addFilter(for: property.id, to: viewId))
        case .sort: return .openSortMenu
        case .calculate: return .openCalculateMenu
        case .group:
            guard let viewId else { return .done }
            try operations.group(by: property.id, in: viewId)
            return .done
        case .hide:
            guard let viewId else { return .done }
            try operations.setVisible(property.id, false, in: viewId)
            return .done
        case .wrap:
            guard let viewId, let view = try store.write({ try $0.view(viewId) }) else { return .done }
            try operations.setWrap(property.id, !view.wraps(property.id), in: viewId)
            return .done
        }
    }

    /// Вопрос перед удалением, как у Notion 7.39 (`notion-delete-property-confirm.png`).
    public func deleteQuestion() throws -> String {
        let title = try store.write { try $0.page(databaseId)?.displayTitle } ?? Page.untitledTitle
        return "Удалить это свойство из «\(title)»? Оно пропадёт из всех видов."
    }

    /// Удаление после подтверждения — в «Удалённые свойства» (значения хранятся).
    public func delete(_ property: DatabaseProperty) throws {
        try operations.setDeleted(property.id, true)
    }

    /// Переименовать; `false` — имя пустое или прежнее, ничего не записано.
    @discardableResult
    public func rename(_ property: DatabaseProperty, to name: String) throws -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != property.name else { return false }
        try operations.renameProperty(property.id, to: trimmed)
        return true
    }

    /// Сменить тип; `false` — тип тот же. На большой базе — в фоне (окно не замирает, SC-305), таблица перечитается
    /// по готовности.
    @discardableResult
    public func changeType(_ property: DatabaseProperty, to kind: PropertyKind) throws -> Bool {
        guard kind != property.kind else { return false }
        if try rowCount() >= DatabaseOperations.backgroundRewriteThreshold {
            operations.startChangeType(property.id, to: kind)
        } else {
            try operations.changeType(property.id, to: kind)
        }
        return true
    }

    /// Строк в базе (с корзиной: их значения тоже переводятся).
    func rowCount() throws -> Int {
        try store.write { tx in
            try tx.fetchTexts(sql: "SELECT COUNT(*) FROM page WHERE parentId = ?", arguments: [.text(databaseId.uuidString.lowercased())])
                .first.flatMap(Int.init) ?? 0
        }
    }

    /// Новое свойство из «+» и окна «Свойства»: имя из поля, пустое — название типа («Число», «Число 1»…), как у Notion.
    /// Колонка встаёт в конец видов.
    @discardableResult
    public func addProperty(named name: String, kind: PropertyKind) throws -> DatabaseProperty {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(try DatabaseCatalog.read(databaseId, in: store).properties.map(\.name))
        return try operations.addProperty(to: databaseId, name: trimmed.isEmpty ? Self.freeName(CellKind.for(kind).title, taken: taken) : trimmed,
                                          kind: kind)
    }

    /// Строки списка типов: ID серый, если в базе уже есть другое ID.
    public func typeRows(current property: DatabaseProperty? = nil, matching query: String = "") throws -> [[PropertyTypePicker.Entry]] {
        var kinds = Set(try DatabaseCatalog.read(databaseId, in: store).properties.map(\.kind))
        if property?.kind == .uniqueId { kinds.remove(.uniqueId) }
        return PropertyTypePicker.rows(existingKinds: kinds, matching: query)
    }

    static func freeName(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var number = 1
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}

/// Подсветка пункта меню стрелками (как у меню 002): черты и серые пункты пропускаются, по кругу.
public enum MenuHighlight {
    /// Следующий выбираемый пункт от `index` на `delta`; без подсветки ↓ — первый, ↑ — последний.
    public static func move(from index: Int?, by delta: Int, selectable: [Bool]) -> Int? {
        let count = selectable.count
        guard count > 0, selectable.contains(true) else { return nil }
        var position = index ?? (delta > 0 ? -1 : count)
        for _ in 0..<count {
            position = ((position + (delta > 0 ? 1 : -1)) % count + count) % count
            if selectable[position] { return position }
        }
        return nil
    }
}
