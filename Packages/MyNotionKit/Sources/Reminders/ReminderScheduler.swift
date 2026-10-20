import AppKit
import Foundation
import NotesCore
import UserNotifications

/// Уведомление о напоминании. Идентификатор — id упоминания даты: повторная постановка заменяет прежнюю (research R11).
public struct ReminderNotificationRequest: Sendable, Hashable {
    public let mentionId: UUID
    public let pageId: UUID
    public let blockId: UUID
    public let title: String
    public let body: String
    /// Когда показать; `nil` — сразу.
    public let fireAt: Date?

    public var identifier: String { mentionId.uuidString.lowercased() }

    public init(mentionId: UUID, pageId: UUID, blockId: UUID, title: String, body: String, fireAt: Date?) {
        self.mentionId = mentionId
        self.pageId = pageId
        self.blockId = blockId
        self.title = title
        self.body = body
        self.fireAt = fireAt
    }
}

/// Центр уведомлений системы за протоколом: тесты подменяют его своим.
public protocol ReminderNotificationCenter: Sendable {
    func add(_ request: ReminderNotificationRequest) async throws
    func pendingIdentifiers() async -> [String]
    func removePending(_ identifiers: [String]) async
    func removeDelivered(_ identifiers: [String]) async
}

/// Ставит уведомления системы по индексу напоминаний (research R11): ближайшие 50 несделанных — в очередь системы;
/// просроченные за 7 дней и не показанные на этом Mac (сон, пришли с другого Mac) — сразу и один раз.
/// Своих таймеров нет: уведомления показывает система, даже если MyNotion закрыт.
@MainActor
public final class ReminderScheduler {
    public static let queueLimit = 50
    public static let catchUpWindow: TimeInterval = 7 * 24 * 60 * 60

    public let index: ReminderIndex
    private let center: any ReminderNotificationCenter
    private let now: @Sendable () -> Date
    /// Подписка снимается в `deinit` — он не привязан к главному потоку.
    nonisolated(unsafe) private var wakeObservers: [NSObjectProtocol] = []

    deinit {
        wakeObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Перестановка идёт — следующая просьба выполнится после неё одной перестановкой.
    private var isRescheduling = false
    private var needsAnotherPass = false

    public init(store: NotesStore, center: any ReminderNotificationCenter, now: @escaping @Sendable () -> Date = Date.init) {
        index = ReminderIndex(store: store)
        self.center = center
        self.now = now
    }

    /// Переставить уведомления по индексу. Зовётся после готовности редактора, при правке индекса и при пробуждении Mac.
    public func reschedule() async {
        guard !isRescheduling else {
            needsAnotherPass = true
            return
        }
        isRescheduling = true
        defer { isRescheduling = false }
        repeat {
            needsAnotherPass = false
            do { try await reschedulePass() } catch { /* индекс перечитается при следующей правке или пробуждении */ }
        } while needsAnotherPass
    }

    private func reschedulePass() async throws {
        let moment = now()
        let pending = Set(await center.pendingIdentifiers())
        var keptIdentifiers: Set<String> = []

        // Просроченные: система их ещё не показала (Mac спал) или здесь их не ставили — сразу, один раз.
        let overdue = try index.activeEntries(firingIn: moment.addingTimeInterval(-Self.catchUpWindow)...moment)
        var shownNow: [UUID] = []
        for entry in overdue {
            let identifier = entry.mentionId.uuidString.lowercased()
            guard entry.deliveredAt == nil || pending.contains(identifier) else { continue }
            if pending.contains(identifier) { await center.removePending([identifier]) }
            // Система не приняла одно — остальные всё равно ставятся; это повторится на следующем проходе.
            guard (try? await center.add(request(for: entry, fireAt: nil))) != nil else { continue }
            shownNow.append(entry.mentionId)
        }
        try index.setDelivered(shownNow, at: moment)

        // Ближайшие будущие — в очередь системы; отданное системе считается показанным в свой момент.
        let upcoming = try index.activeEntries(after: moment, limit: Self.queueLimit)
        for entry in upcoming {
            let identifier = entry.mentionId.uuidString.lowercased()
            guard (try? await center.add(request(for: entry, fireAt: entry.fireAt))) != nil else {
                // Прежнее уведомление в очереди, если было, остаётся.
                if pending.contains(identifier) { keptIdentifiers.insert(identifier) }
                continue
            }
            keptIdentifiers.insert(identifier)
            if entry.deliveredAt != entry.fireAt { try index.setDelivered([entry.mentionId], at: entry.fireAt) }
        }
        try index.clearHandedOver(after: moment, except: Set(upcoming.map(\.mentionId)))
        let stale = pending.subtracting(keptIdentifiers).subtracting(overdue.map { $0.mentionId.uuidString.lowercased() })
        if !stale.isEmpty { await center.removePending(Array(stale).sorted()) }
    }

    private func request(for entry: ReminderEntry, fireAt: Date?) throws -> ReminderNotificationRequest {
        let content = try index.content(of: entry)
        return ReminderNotificationRequest(mentionId: entry.mentionId, pageId: entry.pageId, blockId: entry.blockId,
                                           title: content.title, body: content.body, fireAt: fireAt)
    }

    /// Запись поменяла напоминания: сделанные снимаются с экрана и из очереди (на этом и на другом Mac), остальное
    /// переставляется.
    public func apply(_ change: ReminderIndexChange) async {
        if !change.doneMentionIds.isEmpty {
            let identifiers = change.doneMentionIds.map { $0.uuidString.lowercased() }.sorted()
            await center.removeDelivered(identifiers)
            await center.removePending(identifiers)
        }
        await reschedule()
    }

    /// Пробуждение Mac и смена пояса — переставить: пропущенное во сне показывается сразу (SC-104).
    public func observeWakeAndTimeZone() {
        guard wakeObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        wakeObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reschedule() }
        })
        wakeObservers.append(NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor in await self?.reschedule() }
        })
    }
}

/// Центр уведомлений macOS (`UNUserNotificationCenter`): кнопка «Готово», данные для открытия страницы у блока.
public struct SystemReminderNotificationCenter: ReminderNotificationCenter {
    public static let categoryIdentifier = "reminder"
    public static let doneActionIdentifier = "reminder.done"
    public static let pageIdKey = "pageId"
    public static let blockIdKey = "blockId"
    public static let mentionIdKey = "mentionId"

    public init() {}

    private var center: UNUserNotificationCenter { .current() }

    /// Категория с кнопкой «Готово»: регистрируется при запуске, до первого уведомления.
    public static func registerCategory() {
        let done = UNNotificationAction(identifier: doneActionIdentifier, title: "Готово", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: categoryIdentifier, actions: [done], intentIdentifiers: [], options: []),
        ])
    }

    public func add(_ request: ReminderNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [Self.pageIdKey: request.pageId.uuidString, Self.blockIdKey: request.blockId.uuidString,
                            Self.mentionIdKey: request.mentionId.uuidString]
        let trigger = request.fireAt.map { fireAt in
            UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireAt), repeats: false)
        }
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
    }

    public func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    public func removePending(_ identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func removeDelivered(_ identifiers: [String]) async {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Разрешение macOS — при первом включении «Напомнить», не при запуске (research R11).
    public static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }
}
