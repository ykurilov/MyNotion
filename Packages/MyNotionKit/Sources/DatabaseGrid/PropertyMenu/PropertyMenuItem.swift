import Foundation
import NotesCore

/// Место пункта меню колонки (contracts/database-ui.md, «Меню колонки»), по порядку. Поле имени — шапка меню, не пункт.
public enum PropertyMenuSlot: Int, CaseIterable, Comparable, Sendable {
    case editProperty, changeType
    case filter, sort, group, calculate, hide, wrap
    case insertLeft, insertRight, duplicate, delete

    public static func < (lhs: PropertyMenuSlot, rhs: PropertyMenuSlot) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Группа пункта: между группами — черта.
    var group: Int {
        switch self {
        case .editProperty, .changeType: 0
        case .filter, .sort, .group, .calculate, .hide, .wrap: 1
        default: 2
        }
    }
}

/// Описатель пункта меню колонки: место и название по свойству (`nil` — этому свойству пункт не нужен). Действие —
/// обработчик окна для места; пункт без обработчика не показывается. Пункт — файл в `PropertyMenu/` той истории,
/// которая его вводит (US1 — свойство и колонки, US3 — вид).
public struct PropertyMenuItem: Sendable {
    public let slot: PropertyMenuSlot
    public let title: @Sendable (DatabaseProperty) -> String?

    public init(slot: PropertyMenuSlot, title: @escaping @Sendable (DatabaseProperty) -> String?) {
        self.slot = slot
        self.title = title
    }

    public static var all: [PropertyMenuItem] {
        [editProperty, changeType, filter, sort, group, calculate, hide, wrap, insertLeft, insertRight, duplicate, delete].compactMap { $0 }
    }
}

extension PropertyMenuItem {
    static let editProperty: PropertyMenuItem? = PropertyMenuItem(slot: .editProperty) { _ in "Изменить свойство" }
    /// У «Названия» тип не меняется (data-model.md, `db_property`).
    static let changeType: PropertyMenuItem? = PropertyMenuItem(slot: .changeType) { $0.kind == .title ? nil : "Сменить тип" }
    static let filter: PropertyMenuItem? = PropertyMenuItem(slot: .filter) { _ in "Фильтр" }
    static let sort: PropertyMenuItem? = PropertyMenuItem(slot: .sort) { _ in "Сортировка" }
    static let group: PropertyMenuItem? = PropertyMenuItem(slot: .group) { property in
        [.uniqueId, .files].contains(property.kind) ? nil : "Группировка"
    }
    static let calculate: PropertyMenuItem? = PropertyMenuItem(slot: .calculate) { _ in "Посчитать" }
    static let hide: PropertyMenuItem? = PropertyMenuItem(slot: .hide) { $0.kind == .title ? nil : "Скрыть" }
    static let wrap: PropertyMenuItem? = PropertyMenuItem(slot: .wrap) { _ in "Переносить текст" }
    static let insertLeft: PropertyMenuItem? = PropertyMenuItem(slot: .insertLeft) { _ in "Вставить слева" }
    static let insertRight: PropertyMenuItem? = PropertyMenuItem(slot: .insertRight) { _ in "Вставить справа" }
    static let duplicate: PropertyMenuItem? = PropertyMenuItem(slot: .duplicate) { $0.kind == .title ? nil : "Дублировать свойство" }
    static let delete: PropertyMenuItem? = PropertyMenuItem(slot: .delete) { $0.kind == .title ? nil : "Удалить свойство" }
}

/// Меню колонки из описателей: по местам, черта перед группой (если над ней что-то есть).
public enum PropertyMenu {
    public struct Entry: Sendable {
        public let slot: PropertyMenuSlot?
        public let title: String
        public var isSeparator: Bool { slot == nil }
    }

    public static func entries(items: [PropertyMenuItem], property: DatabaseProperty, handled: Set<PropertyMenuSlot>) -> [Entry] {
        var entries: [Entry] = []
        var lastGroup: Int?
        for item in items.sorted(by: { $0.slot < $1.slot }) {
            guard handled.contains(item.slot), let title = item.title(property) else { continue }
            if let lastGroup, lastGroup != item.slot.group { entries.append(Entry(slot: nil, title: "—")) }
            lastGroup = item.slot.group
            entries.append(Entry(slot: item.slot, title: title))
        }
        return entries
    }

    /// Названия пунктов для обычного свойства (проверки и галерея).
    static func titles(items: [PropertyMenuItem], handled: Set<PropertyMenuSlot>) -> [String] {
        let sample = DatabaseProperty(databaseId: UUIDs.sample, name: "Свойство", kind: .text, sortKey: .between(nil, nil))
        return entries(items: items, property: sample, handled: handled).map(\.title)
    }
}

enum UUIDs {
    static let sample = UUID(uuidString: "0193A1B2-0000-7000-8000-000000000000")!
}
