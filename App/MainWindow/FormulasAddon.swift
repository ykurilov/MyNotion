import AppKit
import Databases
import NotesCore

extension Notification.Name {
    /// Фоновый пересчёт формул базы закончился (`object` — id базы): открытые виды этой базы перечитывают строки.
    static let formulasDidRecompute = Notification.Name("cloud.kurilov.mynotion.formulasDidRecompute")
}

/// Формулы в приложении (US5, research R21): подписчик записи пересчитывает зависящие формулы в транзакции правки,
/// очередь — полные пересчёты в фоне, часы «живых» формул — раз в минуту у открытых видов. Открытый вид базы сообщает
/// о себе `viewOpened` / `viewClosed`.
@MainActor
enum FormulasAddon {
    private(set) static var queue: FormulaRecomputeQueue?
    private(set) static var liveClock: LiveFormulaClock?

    /// До первой записи: подписчик пишет итоги в той же транзакции, что и правка.
    nonisolated static func install(on store: NotesStore) -> FormulaRecomputeQueue {
        let queue = FormulaRecomputeQueue(store: store)
        queue.onFinished { databaseId, _ in
            Task { @MainActor in NotificationCenter.default.post(name: .formulasDidRecompute, object: databaseId) }
        }
        store.addWriteHook(ComputationHook(store: store, queue: queue))
        return queue
    }

    /// После открытия библиотеки: недостающие итоги — в фоне, часы «живых» формул — запущены.
    static func start(_ queue: FormulaRecomputeQueue) {
        self.queue = queue
        queue.fillMissing()
        let clock = LiveFormulaClock(queue: queue)
        clock.start()
        liveClock = clock
    }

    static func viewOpened(_ databaseId: UUID) { liveClock?.viewOpened(databaseId) }
    static func viewClosed(_ databaseId: UUID) { liveClock?.viewClosed(databaseId) }
}
