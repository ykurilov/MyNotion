import Foundation

/// Открытые страницы приложения (research R5): на страницу — один `PageDocument` со своим
/// автосохранением, сколько бы окон её ни показывало. Документ живёт, пока открыт хоть в одном окне.
@MainActor
public final class OpenDocuments {
    public let store: NotesStore
    private let scheduler: any AutosaveScheduler
    private var entries: [UUID: Entry] = [:]

    private struct Entry {
        let autosave: AutosaveCoordinator
        var openCount: Int
    }

    public init(store: NotesStore, scheduler: any AutosaveScheduler = MainThreadAutosaveScheduler()) {
        self.store = store
        self.scheduler = scheduler
    }

    /// Открыть страницу в окне. Каждому `open` — свой `release`.
    public func open(_ pageId: UUID) throws -> PageDocument {
        if var entry = entries[pageId] {
            entry.openCount += 1
            entries[pageId] = entry
            return entry.autosave.document
        }
        guard let content = try store.pageContent(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
        let document = PageDocument(content: content)
        entries[pageId] = Entry(autosave: AutosaveCoordinator(document: document, store: store, scheduler: scheduler), openCount: 1)
        return document
    }

    /// Окно больше не показывает страницу. Закрытая во всех окнах страница записывается и забывается.
    /// Если записать не удалось, документ остаётся в памяти и продолжает попытки.
    public func release(_ pageId: UUID) {
        guard var entry = entries[pageId] else { return }
        entry.openCount -= 1
        if entry.openCount > 0 {
            entries[pageId] = entry
            return
        }
        if entry.autosave.saveNow() {
            entry.autosave.stop()
            entries[pageId] = nil
        } else {
            entry.openCount = 0
            entries[pageId] = entry
        }
    }

    /// Записать все открытые страницы сейчас: уход в фон, выход. `false` — что-то записать не удалось.
    @discardableResult
    public func saveAll() -> Bool {
        var allSaved = true
        for entry in entries.values where !entry.autosave.saveNow() {
            allSaved = false
        }
        return allSaved
    }

    /// Есть ли неудачная запись (для вопроса при выходе).
    public var hasFailedSaves: Bool {
        entries.values.contains { if case .failed = $0.autosave.document.saveStatus { true } else { false } }
    }
}
