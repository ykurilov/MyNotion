import Foundation
@testable import NotesCore

/// Часы автосохранения под управлением теста: время идёт только по `advance(by:)`,
/// и запланированные записи выполняются в порядке своих сроков.
@MainActor
final class ManualAutosaveScheduler: AutosaveScheduler {
    private(set) var now: Duration = .zero
    private var pending: [PendingAction] = []
    private var nextOrder = 0

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> any ScheduledAutosave {
        let entry = PendingAction(dueAt: now + max(delay, .zero), order: nextOrder, action: action)
        nextOrder += 1
        pending.append(entry)
        return entry
    }

    /// Сдвинуть время, выполняя всё, что наступило по дороге.
    func advance(by duration: Duration) {
        let target = now + duration
        while let next = pending.filter({ !$0.isCancelled && $0.dueAt <= target })
            .min(by: { ($0.dueAt, $0.order) < ($1.dueAt, $1.order) }) {
            now = next.dueAt
            next.isCancelled = true
            pending.removeAll { $0.isCancelled }
            next.action()
        }
        pending.removeAll { $0.isCancelled }
        now = target
    }

    var scheduledCount: Int { pending.filter { !$0.isCancelled }.count }

    private final class PendingAction: ScheduledAutosave {
        let dueAt: Duration
        let order: Int
        let action: @MainActor () -> Void
        var isCancelled = false

        init(dueAt: Duration, order: Int, action: @escaping @MainActor () -> Void) {
            self.dueAt = dueAt
            self.order = order
            self.action = action
        }

        func cancel() { isCancelled = true }
    }
}
