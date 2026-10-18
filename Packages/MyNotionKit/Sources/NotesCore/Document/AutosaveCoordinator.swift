import Foundation

/// Автосохранение страницы (FR-014, research R4). Правки пишутся через `idleDelay` после последней;
/// при непрерывном наборе — не позже `maximumDelay` после первой незаписанной (SC-005);
/// сразу — по `saveNow()` при уходе в фон, выходе и закрытии. Неудача — повтор через `retryDelay`.
@MainActor
public final class AutosaveCoordinator {
    public static let idleDelay: Duration = .milliseconds(300)
    public static let maximumDelay: Duration = .seconds(1)
    public static let retryDelay: Duration = .seconds(1)

    public let document: PageDocument
    private let store: NotesStore
    private let scheduler: any AutosaveScheduler
    private var scheduledSave: (any ScheduledAutosave)?
    /// Когда появилась первая незаписанная правка.
    private var firstUnsavedEditAt: Duration?

    public init(document: PageDocument, store: NotesStore, scheduler: any AutosaveScheduler) {
        self.document = document
        self.store = store
        self.scheduler = scheduler
        document.didEdit = { [weak self] in self?.documentDidEdit() }
    }

    private func documentDidEdit() {
        guard document.hasUnsavedChanges else {
            // Правки вернули к записанному: на диске то же, что в окне, писать и повторять нечего.
            markNothingUnsaved()
            return
        }
        if document.saveStatus == .saved { document.saveStatus = .saving }
        let now = scheduler.now
        let firstEdit = firstUnsavedEditAt ?? now
        firstUnsavedEditAt = firstEdit
        let saveAt = min(now + Self.idleDelay, firstEdit + Self.maximumDelay)
        schedule(after: max(.zero, saveAt - now))
    }

    /// Записать всё накопленное сейчас. `false` — запись не удалась, правки остались в памяти.
    @discardableResult
    public func saveNow() -> Bool {
        scheduledSave?.cancel()
        scheduledSave = nil
        let changes = document.unsavedChanges()
        guard !changes.isEmpty else {
            markNothingUnsaved()
            return true
        }
        do {
            let pageId = document.pageId
            let result = try store.write { try PageDocumentWriter.write(changes, pageId: pageId, in: $0) }
            document.didSave(changes, result: result)
            if !result.conflictedBlockIds.isEmpty, let conflicts = try? store.unresolvedConflicts(ofPage: pageId) {
                document.replacePendingConflicts(conflicts)
            }
            firstUnsavedEditAt = nil
            document.saveStatus = .saved
            return true
        } catch {
            document.saveStatus = .failed(reason: SaveStatus.reason(for: error))
            schedule(after: Self.retryDelay)
            return false
        }
    }

    /// Остановить запланированные записи; документ больше не сохраняется сам.
    func stop() {
        scheduledSave?.cancel()
        scheduledSave = nil
        document.didEdit = nil
    }

    /// Несохранённого нет — и «не сохранено» снимается, даже если диск всё ещё недоступен.
    private func markNothingUnsaved() {
        scheduledSave?.cancel()
        scheduledSave = nil
        firstUnsavedEditAt = nil
        document.saveStatus = .saved
    }

    private func schedule(after delay: Duration) {
        scheduledSave?.cancel()
        scheduledSave = scheduler.schedule(after: delay) { [weak self] in
            self?.scheduledSave = nil
            self?.saveNow()
        }
    }
}

/// Часы автосохранения: в приложении — главный поток, в тестах — ручное время.
@MainActor
public protocol AutosaveScheduler: AnyObject {
    /// Монотонное время с произвольного начала.
    var now: Duration { get }
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> any ScheduledAutosave
}

@MainActor
public protocol ScheduledAutosave: AnyObject {
    func cancel()
}

/// Автосохранение на главном потоке приложения.
@MainActor
public final class MainThreadAutosaveScheduler: AutosaveScheduler {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        origin = clock.now
    }

    public var now: Duration { clock.now - origin }

    public func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> any ScheduledAutosave {
        let task = Task { @MainActor in
            try await Task.sleep(for: delay, tolerance: .milliseconds(10))
            action()
        }
        return ScheduledTask(task: task)
    }

    private final class ScheduledTask: ScheduledAutosave {
        let task: Task<Void, any Error>
        init(task: Task<Void, any Error>) { self.task = task }
        func cancel() { task.cancel() }
    }
}
