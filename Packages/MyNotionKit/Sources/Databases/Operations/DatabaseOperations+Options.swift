import Foundation
import GRDB
import NotesCore

/// Порядок списка вариантов в окне ячейки и настройках (data-model.md, `config.optionSort`); порядок хранения не меняется.
public enum OptionSort: String, Sendable, CaseIterable {
    case manual, alphabetical, reverseAlphabetical

    public var title: String {
        switch self {
        case .manual: "Вручную"
        case .alphabetical: "По алфавиту"
        case .reverseAlphabetical: "В обратном порядке"
        }
    }
}

extension StatusGroup {
    /// Название группы статуса, как у Notion 7.39 (To-do, In progress, Complete).
    public var title: String {
        switch self {
        case .todo: "К выполнению"
        case .inProgress: "В работе"
        case .complete: "Завершено"
        }
    }

    /// Варианты нового статуса (contracts/property-types.md, «Цвета вариантов»).
    public var defaultOption: (name: String, color: OptionColor) {
        switch self {
        case .todo: ("Не начато", .default)
        case .inProgress: ("В работе", .blue)
        case .complete: ("Готово", .green)
        }
    }
}

extension OptionColor {
    /// Название цвета в меню «⋯» варианта (Notion 7.39 «Default», «Gray»…).
    public var title: String {
        switch self {
        case .default: "По умолчанию"
        case .gray: "Серый"
        case .brown: "Коричневый"
        case .orange: "Оранжевый"
        case .yellow: "Жёлтый"
        case .green: "Зелёный"
        case .blue: "Синий"
        case .purple: "Фиолетовый"
        case .pink: "Розовый"
        case .red: "Красный"
        }
    }

    /// Цвет нового варианта: случайный из 10, кроме цвета предыдущего (contracts/property-types.md).
    public static func random(after previous: OptionColor?) -> OptionColor {
        allCases.filter { $0 != previous }.randomElement() ?? .default
    }
}

/// Список вариантов, как его видит окно ячейки: без повторов имён с двух Mac (первый по id), в порядке `optionSort`.
public enum OptionList {
    /// Первый по id среди вариантов с тем же названием (без учёта регистра) — им показывается и сливается остальное.
    public static func canonical(_ option: SelectOption, among options: [SelectOption]) -> SelectOption {
        let key = SortableText.make(option.name)
        return options.filter { SortableText.make($0.name) == key }.min { $0.id.uuidString < $1.id.uuidString } ?? option
    }

    public static func shown(in context: PropertyContext) -> [SelectOption] {
        var seen: Set<String> = []
        let unique = context.options.filter { option in
            let canonical = canonical(option, among: context.options)
            guard canonical.id == option.id else { return false }
            return seen.insert(SortableText.make(option.name)).inserted
        }
        switch OptionSort(rawValue: context.config["optionSort"]?.string ?? "") ?? .manual {
        case .manual: return unique
        case .alphabetical: return unique.sorted { compare($0.name, $1.name, context.locale) }
        case .reverseAlphabetical: return unique.sorted { compare($1.name, $0.name, context.locale) }
        }
    }

    private static func compare(_ lhs: String, _ rhs: String, _ locale: Locale) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive], range: nil, locale: locale) == .orderedAscending
    }

    /// Поиск в окне «Найти вариант…»: часть названия без учёта регистра.
    public static func matching(_ query: String, in context: PropertyContext) -> [SelectOption] {
        let key = SortableText.make(query.trimmingCharacters(in: .whitespaces))
        let list = shown(in: context)
        guard !key.isEmpty else { return list }
        return list.filter { SortableText.make($0.name).contains(key) }
    }

    /// Строка «Создать <название>»: текст не пуст и точного варианта нет.
    public static func offersCreation(_ query: String, in context: PropertyContext) -> Bool {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && context.option(named: name) == nil
    }
}

/// Варианты выбора, множественного выбора и статуса (US2, contracts/property-types.md): из ячейки, меню «⋯» варианта
/// и настроек свойства. Каждая правка — один шаг ⌘Z (research R11).
extension DatabaseOperations {
    /// Новый вариант в конце (у статуса — в конце группы, по умолчанию «К выполнению»); цвет — случайный, не как у
    /// последнего.
    @discardableResult
    public func createOption(in propertyId: UUID, named name: String, color: OptionColor? = nil, group: StatusGroup? = nil) throws -> SelectOption {
        try perform("Новый вариант") { transaction in
            let option = try Self.insertOption(in: propertyId, named: name, color: color, group: group, transaction)
            return (option, { try $0.setOptionDeleted(option.id, true) })
        }
    }

    /// Выбрать вариант в ячейке: у выбора и статуса — вместо прежнего, у множественного — добавить или снять.
    /// Повторы имён с двух Mac в значении переводятся на первый вариант.
    public func pickOption(_ optionId: UUID, rowId: UUID, propertyId: UUID) throws {
        try perform("Выбор варианта") { transaction in
            let previous = try transaction.cell(rowId: rowId, propertyId: propertyId)?.value
            try Self.writePick(optionId, rowId: rowId, propertyId: propertyId, transaction)
            return ((), { try $0.setCell(rowId: rowId, propertyId: propertyId, value: previous) })
        }
    }

    /// Enter в окне ячейки: вариант с этим названием (без учёта регистра) или новый — и он же выбран, одним шагом.
    @discardableResult
    public func pickOption(named name: String, rowId: UUID, propertyId: UUID) throws -> SelectOption {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NotesStoreError.invalidRecord("пустое название варианта") }
        return try perform("Выбор варианта") { transaction in
            let previous = try transaction.cell(rowId: rowId, propertyId: propertyId)?.value
            let property = try Self.requireProperty(propertyId, transaction)
            let existing = try transaction.options(ofProperty: propertyId)
            let key = SortableText.make(trimmed)
            var created: SelectOption?
            let option: SelectOption
            if let found = existing.first(where: { SortableText.make($0.name) == key }) {
                option = OptionList.canonical(found, among: existing)
            } else {
                option = try Self.insertOption(in: propertyId, named: trimmed, color: nil, group: nil, transaction)
                created = option
            }
            // Множественный: уже выбранный по имени не снимается — Enter добавляет.
            let current = try transaction.cell(rowId: rowId, propertyId: propertyId)?.value?.array ?? []
            if !(property.kind == .multiSelect && current.contains(.string(option.id.databaseText))) {
                try Self.writePick(option.id, rowId: rowId, propertyId: propertyId, transaction)
            }
            return (option, { operations in
                try operations.withdrawPick(rowId: rowId, propertyId: propertyId, value: previous, created: created?.id)
            })
        }
    }

    /// Снять вариант с ячейки (× на плашке, ⌫ в окне).
    public func removeOption(_ optionId: UUID, rowId: UUID, propertyId: UUID) throws {
        try performChange("Снять вариант") { transaction in
            let previous = try transaction.cell(rowId: rowId, propertyId: propertyId)?.value
            let id = JSONValue.string(optionId.databaseText)
            let next: JSONValue?
            if let list = previous?.array {
                let rest = list.filter { $0 != id }
                next = rest.isEmpty ? nil : .array(rest)
            } else {
                next = previous == id ? nil : previous
            }
            guard next != previous else { return nil }
            try transaction.setCell(rowId: rowId, propertyId: propertyId, value: next)
            return { try $0.setCell(rowId: rowId, propertyId: propertyId, value: previous) }
        }
    }

    public func renameOption(_ optionId: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NotesStoreError.invalidRecord("пустое название варианта") }
        try editOption(optionId, "Переименование варианта") { $0.name = trimmed }
    }

    public func setOptionColor(_ optionId: UUID, to color: OptionColor) throws {
        try editOption(optionId, "Цвет варианта") { $0.color = color.rawValue }
    }

    /// «Удалить» в меню «⋯»: вариант уходит из списка и из всех строк; ⌘Z возвращает и вариант, и значения.
    public func deleteOption(_ optionId: UUID) throws {
        try perform("Удаление варианта") { transaction in
            guard var option = try transaction.option(optionId) else { throw NotesStoreError.invalidRecord("варианта нет") }
            let id = JSONValue.string(optionId.databaseText)
            var previous: [(rowId: UUID, value: JSONValue?, written: JSONValue?)] = []
            var writes: [(rowId: UUID, value: JSONValue?)] = []
            for (rowId, value) in try Self.cellValues(of: option.propertyId, transaction) {
                guard let value else { continue }
                if let list = value.array {
                    guard list.contains(id) else { continue }
                    let rest = list.filter { $0 != id }
                    writes.append((rowId, rest.isEmpty ? nil : .array(rest)))
                } else {
                    guard value == id else { continue }
                    writes.append((rowId, nil))
                }
                previous.append((rowId, value, writes[writes.count - 1].value))
            }
            try transaction.setCells(writes, propertyId: option.propertyId)
            option.deletedAt = Date()
            try transaction.saveOption(option)
            let propertyId = option.propertyId
            return ((), { try $0.restoreOption(optionId, propertyId: propertyId, values: previous) })
        }
    }

    /// Перетащить вариант: встаёт после `previousId` (`nil` — первым) в группе `group` (у статуса; `nil` — та же).
    public func moveOption(_ optionId: UUID, after previousId: UUID?, group: StatusGroup? = nil) throws {
        try performChange("Порядок вариантов") { transaction in
            guard let option = try transaction.option(optionId) else { throw NotesStoreError.invalidRecord("варианта нет") }
            let target = group ?? option.statusGroup
            let siblings = try transaction.options(ofProperty: option.propertyId)
                .filter { $0.id != optionId && $0.statusGroup == target }
                .sorted(by: DatabaseCatalog.optionOrder)
            let index = previousId.flatMap { id in siblings.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
            let before = index > 0 ? siblings[index - 1].sortKey : nil
            let after = index < siblings.count ? siblings[index].sortKey : nil
            var moved = option
            moved.sortKey = Self.key(between: before, after)
            moved.statusGroup = target
            guard moved.sortKey != option.sortKey || moved.statusGroup != option.statusGroup else { return nil }
            try transaction.saveOption(moved)
            return { try $0.placeOption(option) }
        }
    }

    /// «Сортировка» в настройках выбора: вручную, по алфавиту, в обратном порядке.
    public func setOptionSort(_ propertyId: UUID, to sort: OptionSort) throws {
        try performChange("Сортировка вариантов") { transaction in
            var property = try Self.requireProperty(propertyId, transaction)
            let previous = property.config
            property.config["optionSort"] = sort == .manual ? nil : .string(sort.rawValue)
            guard property.config != previous else { return nil }
            try transaction.saveProperty(property)
            return { try $0.setPropertyConfig(propertyId, previous) }
        }
    }

    // MARK: Внутреннее

    nonisolated static func insertOption(in propertyId: UUID, named name: String, color: OptionColor?, group: StatusGroup?,
                                         _ transaction: NotesTransaction) throws -> SelectOption {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NotesStoreError.invalidRecord("пустое название варианта") }
        let property = try requireProperty(propertyId, transaction)
        let all = try transaction.options(ofProperty: propertyId, includingDeleted: true)
        let groupOf: StatusGroup? = property.kind == .status ? (group ?? .todo) : nil
        let last = all.filter { $0.deletedAt == nil }.max { $0.sortKey < $1.sortKey }
        let lastInGroup = all.filter { $0.deletedAt == nil && $0.statusGroup == groupOf }.map(\.sortKey).max()
        return try transaction.saveOption(SelectOption(propertyId: propertyId, name: trimmed,
                                                       color: color ?? .random(after: last?.optionColor),
                                                       sortKey: .between(lastInGroup, nil), statusGroup: groupOf))
    }

    /// Варианты нового статуса: по одному в каждой группе.
    nonisolated static func insertStatusDefaults(in propertyId: UUID, _ transaction: NotesTransaction) throws {
        for group in StatusGroup.allCases {
            _ = try insertOption(in: propertyId, named: group.defaultOption.name, color: group.defaultOption.color, group: group, transaction)
        }
    }

    /// Записать выбор варианта в ячейку; id из значения переводятся на первый вариант своего имени.
    nonisolated static func writePick(_ optionId: UUID, rowId: UUID, propertyId: UUID, _ transaction: NotesTransaction) throws {
        let property = try requireProperty(propertyId, transaction)
        let options = try transaction.options(ofProperty: propertyId)
        func canonical(_ id: UUID) -> UUID {
            options.first { $0.id == id }.map { OptionList.canonical($0, among: options).id } ?? id
        }
        let chosen = JSONValue.string(canonical(optionId).databaseText)
        let value: JSONValue?
        if property.kind == .multiSelect {
            var list: [JSONValue] = []
            for item in try transaction.cell(rowId: rowId, propertyId: propertyId)?.value?.array ?? [] {
                guard let id = item.string.flatMap(UUID.init(uuidString:)) else { continue }
                let merged = JSONValue.string(canonical(id).databaseText)
                if !list.contains(merged) { list.append(merged) }
            }
            if let index = list.firstIndex(of: chosen) { list.remove(at: index) } else { list.append(chosen) }
            value = list.isEmpty ? nil : .array(list)
        } else {
            value = chosen
        }
        try transaction.setCell(rowId: rowId, propertyId: propertyId, value: value)
    }

    private func editOption(_ optionId: UUID, _ actionName: String, _ edit: (inout SelectOption) -> Void) throws {
        try performChange(actionName) { transaction in
            guard let option = try transaction.option(optionId) else { throw NotesStoreError.invalidRecord("варианта нет") }
            var changed = option
            edit(&changed)
            guard changed != option else { return nil }
            try transaction.saveOption(changed)
            return { try $0.placeOption(option, actionName: actionName) }
        }
    }

    /// Вернуть запись варианта как в снимке (имя, цвет, место); шаг повтора — какой она была.
    private func placeOption(_ snapshot: SelectOption, actionName: String = "Порядок вариантов") throws {
        try perform(actionName) { transaction in
            guard let current = try transaction.option(snapshot.id) else { throw NotesStoreError.invalidRecord("варианта нет") }
            var restored = current
            restored.name = snapshot.name
            restored.color = snapshot.color
            restored.sortKey = snapshot.sortKey
            restored.statusGroup = snapshot.statusGroup
            try transaction.saveOption(restored)
            return ((), { try $0.placeOption(current, actionName: actionName) })
        }
    }

    /// Вариант в список или из него (без значений строк) — отмена создания.
    func setOptionDeleted(_ optionId: UUID, _ isDeleted: Bool) throws {
        try perform(isDeleted ? "Удаление варианта" : "Новый вариант") { transaction in
            guard var option = try transaction.option(optionId) else { throw NotesStoreError.invalidRecord("варианта нет") }
            option.deletedAt = isDeleted ? Date() : nil
            try transaction.saveOption(option)
            return ((), { try $0.setOptionDeleted(optionId, !isDeleted) })
        }
    }

    /// Отмена удаления: вариант и прежние значения строк.
    /// ⌘Z удаления: прежнее значение — только в ячейки, где осталось записанное удалением. Ячейку, которую с тех пор
    /// поправили (здесь или на другом Mac), отмена не трогает.
    private func restoreOption(_ optionId: UUID, propertyId: UUID, values: [(rowId: UUID, value: JSONValue?, written: JSONValue?)]) throws {
        try perform("Удаление варианта") { transaction in
            guard var option = try transaction.option(optionId) else { throw NotesStoreError.invalidRecord("варианта нет") }
            option.deletedAt = nil
            try transaction.saveOption(option)
            let current = Dictionary(try Self.cellValues(of: propertyId, transaction), uniquingKeysWith: { first, _ in first })
            let untouched = values.filter { (current[$0.rowId] ?? nil) == $0.written }.map { (rowId: $0.rowId, value: $0.value) }
            try transaction.setCells(untouched, propertyId: propertyId)
            return ((), { try $0.deleteOption(optionId) })
        }
    }

    /// Отмена Enter: прежнее значение ячейки и созданный вариант — из списка.
    private func withdrawPick(rowId: UUID, propertyId: UUID, value: JSONValue?, created: UUID?) throws {
        try perform("Выбор варианта") { transaction in
            let current = try transaction.cell(rowId: rowId, propertyId: propertyId)?.value
            try transaction.setCell(rowId: rowId, propertyId: propertyId, value: value)
            if let created, var option = try transaction.option(created) {
                option.deletedAt = Date()
                try transaction.saveOption(option)
            }
            return ((), { try $0.repeatPick(rowId: rowId, propertyId: propertyId, value: current, created: created, previous: value) })
        }
    }

    private func repeatPick(rowId: UUID, propertyId: UUID, value: JSONValue?, created: UUID?, previous: JSONValue?) throws {
        try perform("Выбор варианта") { transaction in
            if let created, var option = try transaction.option(created) {
                option.deletedAt = nil
                try transaction.saveOption(option)
            }
            try transaction.setCell(rowId: rowId, propertyId: propertyId, value: value)
            return ((), { try $0.withdrawPick(rowId: rowId, propertyId: propertyId, value: previous, created: created) })
        }
    }
}
