import AppKit
import Foundation
import NotesCore
import Observation
import PageEditor
import PageSearch
import PageTree

/// Общее для всех окон приложения (FR-029): база, открытые страницы, дерево, корзина и синхронизация.
/// У каждого окна свой `MainWindowModel` над этой библиотекой. Одна страница в двух окнах — один `PageDocument`
/// (research R5): набор в одном окне сразу виден в другом.
@MainActor
@Observable
final class PagesLibrary {
    let store: NotesStore
    @ObservationIgnored let openDocuments: OpenDocuments
    /// Дерево без корзины.
    private(set) var tree = PageTreeSnapshot(allPages: [])
    /// Меняется при каждом перечитывании дерева.
    private(set) var treeRevision = 0
    private(set) var trashEntries: [Page] = []
    /// Страницы корзины вместе с подстраницами — для упоминаний «Удалённая страница».
    private(set) var trashedPageIds: Set<UUID> = []
    /// Напоминания (US3): индекс, уведомления системы, «Готово».
    @ObservationIgnored let reminders: ReminderNotifications
    /// Синхронизация между Mac (US5); выключена — ничего не делает.
    @ObservationIgnored private(set) var sync: SyncController!
    /// Окно, открытое при запуске: его ждут замеры, галерея и снимки окна.
    @ObservationIgnored private(set) var firstWindow: MainWindowModel!
    @ObservationIgnored private var isFirstWindowClaimed = false
    @ObservationIgnored private var windows: [WeakWindow] = []
    /// «Файл → Новое окно»: ставит первое окно (открывать окна SwiftUI умеет только из вида).
    @ObservationIgnored var openNewWindow: (@MainActor () -> Void)?

    private struct WeakWindow {
        weak var model: MainWindowModel?
    }

    init(store: NotesStore, startsSync: Bool = true, reminders: ReminderNotifications) {
        self.store = store
        self.reminders = reminders
        openDocuments = OpenDocuments(store: store)
        reloadTree()
        sync = SyncController(store: store, openDocuments: openDocuments, startsEngine: startsSync)
        sync.onRemoteChange = { [weak self] _ in self?.remoteChangesApplied() }
        firstWindow = MainWindowModel(library: self, opening: nil)
        reminders.openBlock = { [weak self] pageId, blockId in self?.openBlock(blockId, inPage: pageId) }
    }

    /// Щелчок по уведомлению: страница в окне, где работают, курсор — у блока с датой; свёрнутые предки раскрываются.
    func openBlock(_ blockId: UUID, inPage pageId: UUID) {
        guard tree.page(pageId) != nil else { return }
        let window = activeWindow ?? firstWindow
        window?.select(pageId, revealing: blockId)
        window?.window?.makeKeyAndOrderFront(nil)
    }

    /// Модель для нового окна: первому — созданная при запуске, следующим — новая с той же страницей,
    /// что открыта в окне, где сейчас работают.
    func modelForNewWindow() -> MainWindowModel {
        if !isFirstWindowClaimed {
            isFirstWindowClaimed = true
            return firstWindow
        }
        return MainWindowModel(library: self, opening: activeWindow?.openPageId)
    }

    func register(_ window: MainWindowModel) {
        windows.removeAll { $0.model == nil }
        windows.append(WeakWindow(model: window))
    }

    func unregister(_ window: MainWindowModel) {
        windows.removeAll { $0.model == nil || $0.model === window }
    }

    var windowModels: [MainWindowModel] { windows.compactMap(\.model) }

    /// Окно, в котором сейчас работают (ключевое), иначе первое из открытых.
    var activeWindow: MainWindowModel? {
        windowModels.first { $0.window?.isKeyWindow == true } ?? windowModels.first
    }

    /// Записать все открытые страницы сейчас: уход в фон, выход. `false` — что-то не записалось.
    @discardableResult
    func saveAll() -> Bool {
        openDocuments.saveAll()
    }

    var hasFailedSaves: Bool { openDocuments.hasFailedSaves }

    func reloadTree() {
        let all = (try? store.pageOutline()) ?? []
        tree = PageTreeSnapshot(allPages: all)
        trashEntries = NotesStore.trashEntries(in: all)
        trashedPageIds = Set(all.lazy.map(\.id).filter { self.tree.page($0) == nil })
        treeRevision += 1
    }

    /// Операция с деревом в любом окне (и её отмена): дерево перечитывается один раз, окна сверяют свои страницы.
    func treeDidChange(_ touchedPageIds: Set<UUID>) {
        reloadTree()
        let windows = windowModels
        let released = windows.map { $0.releaseIfTouched(touchedPageIds) }
        for (window, pageId) in zip(windows, released) { window.treeDidChange(touchedPageIds, reopening: pageId) }
    }

    /// Иконка сменилась: дерево перечитать, окнам с этой страницей — новую иконку.
    func iconDidChange(_ pageId: UUID) {
        reloadTree()
        guard let stored = tree.page(pageId) else { return }
        openDocuments.document(for: pageId)?.adoptIcon(of: stored)
    }

    /// Правки с другого Mac легли в базу; открытые страницы их уже приняли (research R5).
    private func remoteChangesApplied() {
        reloadTree()
        for window in windowModels { window.remoteChangesApplied() }
    }
}
