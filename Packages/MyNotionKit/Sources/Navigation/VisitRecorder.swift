import Foundation
import NotesCore

/// Запись открытий для «Недавних» (research R4): страница попадает в `visitedAt`, если пробыла открытой в активной
/// вкладке не меньше 2 секунд или в ней правили. Листание дерева стрелками не засоряет недавние и синхронизацию.
/// Запись — одно изменение страницы; «изменено» от неё не меняется.
@MainActor
public final class VisitRecorder {
    /// Отложенное действие: через сколько секунд сработать; возвращает отмену.
    public typealias Scheduler = @MainActor (_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)

    public static let minimumStay: TimeInterval = 2

    private let store: NotesStore
    private let now: () -> Date
    private let schedule: Scheduler
    private let onRecorded: (UUID) -> Void
    private var current: (pageId: UUID, isRecorded: Bool)?
    private var cancelPending: (@MainActor () -> Void)?

    /// `schedule` и `now` подменяются в тестах; в приложении — настоящие часы.
    public init(store: NotesStore, now: @escaping () -> Date = Date.init, schedule: @escaping Scheduler = VisitRecorder.liveSchedule,
                onRecorded: @escaping (UUID) -> Void = { _ in }) {
        self.store = store
        self.now = now
        self.schedule = schedule
        self.onRecorded = onRecorded
    }

    /// Активная вкладка показывает страницу (`nil` — страницы нет). Та же страница — не новое открытие.
    public func pageOpened(_ pageId: UUID?) {
        guard pageId != current?.pageId else { return }
        cancelPending?()
        cancelPending = nil
        current = pageId.map { ($0, false) }
        guard let pageId else { return }
        cancelPending = schedule(Self.minimumStay) { [weak self] in
            self?.cancelPending = nil
            self?.record(pageId)
        }
    }

    /// В открытой странице правили: запись сразу, один раз за пребывание.
    public func pageEdited(_ pageId: UUID) {
        guard current?.pageId == pageId, current?.isRecorded == false else { return }
        cancelPending?()
        cancelPending = nil
        record(pageId)
    }

    private func record(_ pageId: UUID) {
        guard current?.pageId == pageId, current?.isRecorded == false else { return }
        current?.isRecorded = true
        let date = now()
        let wrote = (try? store.write { transaction -> Bool in
            guard var page = try transaction.page(pageId) else { return false }
            page.visitedAt = date
            try transaction.updatePage(page)
            return true
        }) ?? false
        if wrote { onRecorded(pageId) }
    }

    /// Настоящие часы: отсчёт на главном потоке, отмена гасит его.
    public static let liveSchedule: Scheduler = { seconds, action in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }
}
