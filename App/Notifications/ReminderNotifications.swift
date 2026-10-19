import AppKit
import Foundation
import NotesCore
import Observation
import PageEditor
import Reminders
import UserNotifications

/// Напоминания в приложении (research R11): индекс пишется с текстом с первой записи, уведомления ставятся
/// после готовности редактора, а не при запуске. Щелчок по уведомлению открывает страницу у блока, «Готово» —
/// отмечает сделанным на всех Mac.
@MainActor
@Observable
final class ReminderNotifications: NSObject, UNUserNotificationCenterDelegate {
    @ObservationIgnored let store: NotesStore
    @ObservationIgnored private let scheduler: ReminderScheduler
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Открыть страницу у блока (окно, где работают).
    @ObservationIgnored var openBlock: (@MainActor (_ pageId: UUID, _ blockId: UUID) -> Void)?
    /// Сделанные напоминания: просроченная дата с ними не красная.
    private(set) var doneReminderIds: Set<UUID> = []
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var waitingChanges: [ReminderIndexChange] = []

    /// `clockOffset` — сдвиг часов приложения для проверки (`--reminders-clock-offset`); система живёт по своим.
    init(store: NotesStore, clockOffset: TimeInterval = 0) {
        self.store = store
        let now: @Sendable () -> Date = { Date().addingTimeInterval(clockOffset) }
        self.now = now
        scheduler = ReminderScheduler(store: store, center: SystemReminderNotificationCenter(), now: now)
        super.init()
        doneReminderIds = (try? scheduler.index.doneMentionIds()) ?? []
    }

    /// Подписать индекс напоминаний на записи — до первой записи, как поиск и очередь синхронизации.
    func installIndex() {
        store.addWriteHook(ReminderIndexer { [weak self] change in
            Task { @MainActor in self?.indexChanged(change) }
        })
    }

    /// Редактор готов: категория «Готово», делегат, наблюдение сна и первая перестановка.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        SystemReminderNotificationCenter.registerCategory()
        UNUserNotificationCenter.current().delegate = self
        scheduler.observeWakeAndTimeZone()
        let waiting = waitingChanges
        waitingChanges = []
        Task {
            for change in waiting where !change.doneMentionIds.isEmpty { await scheduler.apply(change) }
            await scheduler.reschedule()
        }
    }

    private func indexChanged(_ change: ReminderIndexChange) {
        if !change.doneMentionIds.isEmpty || change.indexChanged { doneReminderIds = (try? scheduler.index.doneMentionIds()) ?? [] }
        guard isStarted else {
            waitingChanges.append(change)
            return
        }
        Task { await scheduler.apply(change) }
    }

    /// Первое «Напомнить»: разрешение macOS. Отказ — календарик покажет подсказку.
    func requestPermission() async -> Bool {
        await SystemReminderNotificationCenter.requestAuthorization()
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let mentionId = (info[SystemReminderNotificationCenter.mentionIdKey] as? String).flatMap(UUID.init(uuidString:))
        let pageId = (info[SystemReminderNotificationCenter.pageIdKey] as? String).flatMap(UUID.init(uuidString:))
        let blockId = (info[SystemReminderNotificationCenter.blockIdKey] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run {
            if action == SystemReminderNotificationCenter.doneActionIdentifier, let mentionId {
                markDone(mentionId)
            } else if action == UNNotificationDefaultActionIdentifier, let pageId, let blockId {
                NSApp.activate()
                openBlock?(pageId, blockId)
            }
        }
    }

    /// «Готово»: отметка уходит на другие Mac, уведомления снимаются здесь и там.
    func markDone(_ mentionId: UUID) {
        try? store.write { try $0.setReminderDone(mentionId, at: now()) }
    }
}
