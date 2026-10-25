import AppKit
import Attachments
import DatabaseGrid
import Databases
import Foundation
import NotesCore
import Observation
import PageEditor
import PageSearch
import PageTree
import PageVersions
import VisualStyle

/// Общее для всех окон приложения (FR-029): база, открытые страницы, дерево, корзина и синхронизация.
/// У каждого окна свой `MainWindowModel` над этой библиотекой. Одна страница в двух окнах — один `PageDocument`
/// (research R5): набор в одном окне сразу виден в другом.
@MainActor
@Observable
final class PagesLibrary {
    let store: NotesStore
    /// Копии файлов блоков (US5): рядом с базой, в `Attachments/`.
    @ObservationIgnored let attachments: AttachmentStore
    @ObservationIgnored let openDocuments: OpenDocuments
    /// Дерево без корзины.
    private(set) var tree = PageTreeSnapshot(allPages: [])
    /// Меняется при каждом перечитывании дерева.
    private(set) var treeRevision = 0
    private(set) var trashEntries: [Page] = []
    /// Избранные страницы по порядку и пять последних, где побывали (US2). Корзина в них не попадает.
    private(set) var favoritePageIds: [UUID] = []
    private(set) var recentPageIds: [UUID] = []
    /// Шаблоны по порядку (US7): свой раздел панели.
    private(set) var templatePageIds: [UUID] = []
    /// Меняется при каждом перечитывании «Избранного» и «Недавних»: разделы перечитывают строки.
    private(set) var sectionsRevision = 0
    /// Страницы корзины вместе с подстраницами — для упоминаний «Удалённая страница».
    private(set) var trashedPageIds: Set<UUID> = []
    /// Те же страницы корзины: название и иконка для вкладки с заглушкой «Страница в корзине» (US3).
    private(set) var trashedPagesById: [UUID: Page] = [:]
    /// Напоминания (US3): индекс, уведомления системы, «Готово».
    @ObservationIgnored let reminders: ReminderNotifications
    /// Синхронизация между Mac (US5); выключена — ничего не делает.
    @ObservationIgnored private(set) var sync: SyncController!
    /// История версий страниц (003, US6).
    @ObservationIgnored private(set) var versions: AppPageVersions!
    /// Окно, открытое при запуске: его ждут замеры, галерея и снимки окна.
    @ObservationIgnored private(set) var firstWindow: MainWindowModel!
    @ObservationIgnored private var isFirstWindowClaimed = false
    @ObservationIgnored private var windows: [WeakWindow] = []
    /// «Файл → Новое окно»: ставит первое окно (открывать окна SwiftUI умеет только из вида).
    @ObservationIgnored var openNewWindow: (@MainActor () -> Void)?
    /// Страница окна, которое сейчас открывает команда `open --new-window`: следующая новая модель берёт её, а не страницу
    /// окна, где работают.
    @ObservationIgnored var pageForNextNewWindow: UUID?

    private struct WeakWindow {
        weak var model: MainWindowModel?
    }

    init(store: NotesStore, startsSync: Bool = true, reminders: ReminderNotifications, versionTiming: PageVersionRecorder.Timing = .standard) {
        self.store = store
        self.reminders = reminders
        attachments = AttachmentStore(store: store, folder: AttachmentStore.folder(forDatabaseAt: store.database.url))
        try? attachments.abandonInterruptedCopies()
        openDocuments = OpenDocuments(store: store)
        MediaBlocks.install(AppMediaServices(attachments: attachments, openDocuments: openDocuments))
        // 004: таблица встроенной базы и страницы-базы (US1).
        DatabaseBlockViewFactory.install(library: self)
        reloadTree()
        sync = SyncController(store: store, openDocuments: openDocuments, attachments: attachments, startsEngine: startsSync)
        sync.onRemoteChange = { [weak self] _ in self?.remoteChangesApplied() }
        versions = AppPageVersions(store: store, deviceName: sync.deviceName, timing: versionTiming)
        firstWindow = MainWindowModel(library: self, opening: nil, restoresTabs: true)
        reminders.openBlock = { [weak self] pageId, blockId in self?.openBlock(blockId, inPage: pageId) }
        // Первое «Напомнить» в окне даты ячейки — разрешение macOS, как у дат в тексте.
        DateReminderPermission.request = { [reminders] in Task { _ = await reminders.requestPermission() } }
    }

    /// Щелчок по уведомлению: страница в окне, где работают, курсор — у блока с датой; свёрнутые предки раскрываются.
    func openBlock(_ blockId: UUID, inPage pageId: UUID) {
        let window = activeWindow ?? firstWindow
        // Напоминание ячейки даты (US2): строки базы в дереве нет — строка открывается на всю страницу.
        if tree.page(pageId) == nil {
            guard (try? store.write({ try $0.page(pageId) })) != nil else { return }
            window?.openRow(pageId, mode: .fullPage)
            window?.window?.makeKeyAndOrderFront(nil)
            return
        }
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
        defer { pageForNextNewWindow = nil }
        return MainWindowModel(library: self, opening: pageForNextNewWindow ?? activeWindow?.openPageId)
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

    /// Страница удалена навсегда (нет ни в дереве, ни в корзине, ни в базе — строк баз в дереве нет):
    /// вкладки пропускают её в «назад/вперёд».
    func isDeletedForever(_ pageId: UUID) -> Bool {
        tree.page(pageId) == nil && trashedPagesById[pageId] == nil && (try? store.page(pageId)) == nil
    }

    /// Строка базы не в корзине: в дереве строк нет (research R1), поэтому — по записи в базе.
    func databaseRow(_ pageId: UUID) -> Page? {
        guard tree.page(pageId) == nil, trashedPagesById[pageId] == nil, let page = try? store.page(pageId),
              page.trashedAt == nil, page.parentId.map(tree.isDatabase) == true else { return nil }
        return page
    }

    /// Запись корзины, в которой лежит страница (сама страница или её предок), — её возвращает «Вернуть».
    func trashEntry(containing pageId: UUID) -> UUID? {
        var page = trashedPagesById[pageId]
        while let current = page {
            if current.trashedAt != nil { return current.id }
            page = current.parentId.flatMap { trashedPagesById[$0] }
        }
        return nil
    }

    /// Записать все открытые страницы сейчас: уход в фон, выход. `false` — что-то не записалось.
    @discardableResult
    func saveAll() -> Bool {
        // Место прокрутки активных вкладок — вместе с правками: выход по ⌘Q окна уже не закрывает.
        for window in windowModels { window.saveTabs() }
        return openDocuments.saveAll()
    }

    var hasFailedSaves: Bool { openDocuments.hasFailedSaves }

    func reloadTree() {
        // Строки баз дерево не читает (их тысячи): только страницы, базы и корзина (research R1).
        let outline = (try? store.treeOutline()) ?? (pages: [], databases: [:])
        let all = outline.pages
        tree = PageTreeSnapshot(allPages: all, databases: outline.databases)
        trashEntries = NotesStore.trashEntries(in: all)
        trashedPagesById = Dictionary(all.lazy.filter { self.tree.page($0.id) == nil }.map { ($0.id, $0) }) { first, _ in first }
        trashedPageIds = Set(trashedPagesById.keys)
        treeRevision += 1
        favoritePageIds = ((try? store.favoritePages()) ?? []).map(\.id)
        recentPageIds = recentIds()
        templatePageIds = tree.templates.map(\.id)
        sectionsRevision += 1
    }

    /// Запись открытия легла в базу: перечитываются только «Недавние», дерево и страницы остаются как были.
    func reloadRecents() {
        let ids = recentIds()
        guard ids != recentPageIds else { return }
        recentPageIds = ids
        sectionsRevision += 1
    }

    private func recentIds() -> [UUID] {
        ((try? store.recentPages(limit: Metrics.Sidebar.recentRowCount)) ?? []).map(\.id)
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

    /// Правки с другого Mac (или записи команд мимо документов) легли в базу; открытые страницы их уже приняли (research R5).
    func remoteChangesApplied() {
        // Строки, созданные без связи на двух Mac, могли получить один номер ID: позже созданная берёт следующий.
        try? DatabaseOperations.repairDuplicateIds(in: store)
        reloadTree()
        // Ячейки, свойства, виды с другого Mac: открытые таблицы перечитывают себя.
        DatabaseOperations.announce(nil)
        for window in windowModels { window.remoteChangesApplied() }
    }
}
