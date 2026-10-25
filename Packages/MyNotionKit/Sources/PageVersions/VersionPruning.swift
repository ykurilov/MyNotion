import Foundation
import NotesCore

/// Прореживание истории (spec, Clarifications; по умолчанию, ждёт Юрия): младше суток — все версии; от суток до 30 дней —
/// последняя в каждом часе; старше — последняя в каждом дне; последняя версия страницы — всегда. Снимки «до восстановления»
/// (contracts/page-operations.md: версия «до восстановления» остаётся) прореживаются тем же правилом, но отдельно от
/// остальных: версия «после» того же часа их не вытесняет, и к виду до восстановления можно вернуться и без ⌘Z. Так же
/// отдельно живут снимки «до правки агента» (005): правка агента не вытесняет вид страницы до неё.
public enum VersionPruning {
    static let keepAllAge: TimeInterval = 86_400
    static let hourlyAge: TimeInterval = 30 * 86_400

    /// Версии одной страницы, которые пора стереть.
    public static func versionsToRemove(_ versions: [VersionStamp], now: Date, calendar: Calendar = .current) -> Set<UUID> {
        func isLater(_ lhs: VersionStamp, than rhs: VersionStamp) -> Bool {
            (lhs.createdAt, lhs.id.uuidString) > (rhs.createdAt, rhs.id.uuidString)
        }
        guard let latest = versions.max(by: { isLater($1, than: $0) }) else { return [] }
        // Час или день → последняя версия в нём. Последняя версия страницы — жилец своей корзины всегда.
        var kept: [Bucket: VersionStamp] = [:]
        for version in versions {
            guard let bucket = bucket(of: version, now: now, calendar: calendar) else { continue }
            if let previous = kept[bucket], previous.id == latest.id || isLater(previous, than: version) { continue }
            kept[bucket] = version
        }
        let keptIds = Set(kept.values.map(\.id))
        return Set(versions.filter { bucket(of: $0, now: now, calendar: calendar) != nil && !keptIds.contains($0.id) && $0.id != latest.id }.map(\.id))
    }

    /// Корзина версии: час (от суток до 30 дней) или день (старше); младше суток — без корзины, остаётся.
    /// У снимков «до восстановления» и «до правки агента» корзины свои.
    private struct Bucket: Hashable {
        let isDay: Bool
        let start: Date
        let isBeforeRestore: Bool
        let isAgentCheckpoint: Bool
    }

    private static func bucket(of version: VersionStamp, now: Date, calendar: Calendar) -> Bucket? {
        let age = now.timeIntervalSince(version.createdAt)
        guard age >= keepAllAge else { return nil }
        let isDay = age >= hourlyAge
        return calendar.dateInterval(of: isDay ? .day : .hour, for: version.createdAt).map {
            Bucket(isDay: isDay, start: $0.start, isBeforeRestore: version.isBeforeRestore, isAgentCheckpoint: version.isAgentCheckpoint)
        }
    }
}

/// Прореживание раз в сутки после готовности редактора; отметка последнего прохода — в `app_meta` этого Mac.
public final class VersionPruner: Sendable {
    static let lastRunKey = "pageVersions.lastPrunedAt"
    let versions: PageVersionStore
    let store: NotesStore
    let now: @Sendable () -> Date
    let calendar: Calendar

    public init(versions: PageVersionStore, store: NotesStore, now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .current) {
        self.versions = versions
        self.store = store
        self.now = now
        self.calendar = calendar
    }

    /// Проредить, если с прошлого прохода прошли сутки. `true` — проход был.
    @discardableResult
    public func pruneIfDue() throws -> Bool {
        let now = now()
        if let last = try store.appMeta(Self.lastRunKey).flatMap(Double.init), now.timeIntervalSince1970 - last < VersionPruning.keepAllAge {
            return false
        }
        for stamps in try versions.allVersionStamps().values {
            try versions.delete(VersionPruning.versionsToRemove(stamps, now: now, calendar: calendar))
        }
        try store.setAppMeta(Self.lastRunKey, String(now.timeIntervalSince1970))
        return true
    }
}
