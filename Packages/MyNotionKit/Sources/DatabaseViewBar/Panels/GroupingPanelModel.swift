import Databases
import Foundation
import NotesCore

/// Окно группировки без отрисовки (`notion-group-settings.png`, `notion-group-by-list.png`, `notion-group-sort-options.png`).
public struct GroupingPanelModel: Sendable, Hashable {
    /// Шаг групп по типу свойства.
    public enum Bucket: Sendable, Hashable {
        case none
        /// Дата: день, неделя, месяц, год, относительно.
        case date(selected: String)
        /// Число: от, до, шаг.
        case number(from: String, to: String, step: String)
        /// Статус: «По группам».
        case status(byGroups: Bool)
    }

    public struct GroupRow: Sendable, Hashable {
        public let key: String
        public let label: GroupLabel
        public let isHidden: Bool
    }

    public let settings: GroupSettings?
    public let property: DatabaseProperty?
    public let groups: [GroupRow]

    public init(view: DatabaseView, catalog: DatabaseCatalog, groups: [ViewGroup]?) {
        settings = view.groupSettings
        property = settings.flatMap { catalog.propertiesById[$0.propertyId] }
        self.groups = property == nil ? [] : (groups ?? []).map { GroupRow(key: $0.key, label: $0.label, isHidden: $0.isHidden) }
    }

    public var isGrouped: Bool { property != nil }

    public static let sortChoices: [(sort: GroupSort, title: String)] = [
        (.manual, "Вручную"), (.alphabetical, "По алфавиту"), (.reverseAlphabetical, "В обратном порядке"),
    ]

    public static let dateBuckets: [(key: String, title: String)] = [
        ("day", "День"), ("week", "Неделя"), ("month", "Месяц"), ("year", "Год"), ("relative", "Относительно"),
    ]

    public var sortTitle: String { Self.sortChoices.first { $0.sort == (settings?.groupSort ?? .manual) }?.title ?? "Вручную" }

    public var bucket: Bucket {
        guard let property, let settings else { return .none }
        switch property.kind {
        case .status:
            return .status(byGroups: settings.bucket?.string == "group")
        case .date:
            return .date(selected: settings.bucket?.string ?? "month")
        case .createdTime, .lastEditedTime:
            return .date(selected: settings.bucket?.string ?? "day")
        case .number:
            return numberBucket(settings.bucket)
        case .formula, .rollup:
            switch FilterValueKind(property) {
            case .date: return .date(selected: settings.bucket?.string ?? "month")
            case .number: return numberBucket(settings.bucket)
            default: return .none
            }
        default:
            return .none
        }
    }

    private func numberBucket(_ bucket: JSONValue?) -> Bucket {
        .number(from: FilterValues.plain(bucket?["from"]?.number ?? 0), to: FilterValues.plain(bucket?["to"]?.number ?? 1_000),
                step: FilterValues.plain(bucket?["step"]?.number ?? 100))
    }

    /// Подпись шага даты.
    public static func dateBucketTitle(_ key: String) -> String { dateBuckets.first { $0.key == key }?.title ?? key }

    /// Шаг числа из полей; шаг не больше нуля или «до» не больше «от» — `nil` (не записывать).
    public static func numberBucket(from: String, to: String, step: String) -> JSONValue? {
        guard let from = FilterValues.number(from).number, let to = FilterValues.number(to).number,
              let step = FilterValues.number(step).number, step > 0, to > from else { return nil }
        return ["from": .number(from), "to": .number(to), "step": .number(step)]
    }

    public var hideEmpty: Bool { settings?.hideEmpty ?? true }

    /// Все группы скрыты — кнопка «Показать все», иначе «Скрыть все».
    public var allHidden: Bool { !groups.isEmpty && groups.allSatisfy(\.isHidden) }

    /// Группу отпустили на место вставки `insertion` (0…число групп) — индекс для `moveGroup`.
    public func moveIndex(of key: String, insertion: Int) -> Int? {
        guard let from = groups.firstIndex(where: { $0.key == key }) else { return nil }
        let target = insertion > from ? insertion - 1 : insertion
        return target == from ? nil : target
    }
}
