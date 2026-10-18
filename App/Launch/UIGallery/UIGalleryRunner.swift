import AppKit
import NotesCore
import NotionImport
import PageEditor
import PageTree
import Synchronization
import UIGallery
import VisualStyle

/// Галерея состояний интерфейса (флаг `--ui-gallery <папка>`, plan.md, «Проверка интерфейса»): окно по очереди
/// приводится в каждое состояние каталога `GalleryCatalog`, снимок каждого — PNG, рядом `index.html` и `manifest.json`.
@MainActor
final class UIGalleryRunner {
    /// Пауза после приведения окна в состояние: дорисовать текст, меню и поповеры.
    static let settleDelay: Duration = .milliseconds(450)

    private static var current: UIGalleryRunner?

    private let model: MainWindowModel
    private let library: GalleryLibrary
    private let failingWrites: FailingWrites
    private let folder: URL
    private var window: NSWindow!
    private var isTrashShown = false
    private var missing: [String: String] = [:]

    private let filter: String?

    private init(model: MainWindowModel, library: GalleryLibrary, failingWrites: FailingWrites, folder: URL, filter: String?) {
        self.filter = filter
        self.model = model
        self.library = library
        self.failingWrites = failingWrites
        self.folder = folder
    }

    // MARK: Подготовка базы

    /// Наполнить временную базу и открыть образец. Зовётся до первого окна.
    static func prepareLibrary(in store: NotesStore) throws -> (GalleryLibrary, FailingWrites) {
        let failingWrites = FailingWrites()
        store.addWriteHook(failingWrites)
        let library = try GalleryLibrary.create(in: store)
        try store.saveWindowState(WindowState(windowId: WindowState.mainWindowId, openPageId: library.sample.page.id,
                                              collapsedPageIds: [library.archive]))
        return (library, failingWrites)
    }

    /// Окно готово: снять все состояния и выйти. Повторная готовность (новая страница) — не новый запуск.
    static func editorReady(model: MainWindowModel, prepared: (GalleryLibrary, FailingWrites)?, folder: URL, filter: String?) {
        guard current == nil else { return }
        guard let (library, failingWrites) = prepared else {
            FileHandle.standardError.write(Data("Галерея: база не подготовлена\n".utf8))
            NSApp.terminate(nil)
            return
        }
        let runner = UIGalleryRunner(model: model, library: library, failingWrites: failingWrites, folder: folder, filter: filter)
        current = runner
        Task { await runner.run() }
    }

    // MARK: Съёмка

    private func run() async {
        let started = ContinuousClock.now
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            FileHandle.standardError.write(Data("Галерея: нет окна\n".utf8))
            NSApp.terminate(nil)
            return
        }
        self.window = window
        // Курсор текста на каждом снимке: и в неключевом окне, и без мигания.
        TextCaret.isPreviewMode = true
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("Галерея: папка не создана: \(error.localizedDescription)\n".utf8))
            NSApp.terminate(nil)
            return
        }

        // Пустая корзина — после остальных состояний корзины: фильтр порядок не меняет.
        let shots = GalleryCatalog.shots.filter { shot in filter.map { shot.state.id.contains($0) } ?? true }
        for shot in shots {
            await capture(shot)
        }
        await reset()
        writeReport(shots)
        let seconds = (ContinuousClock.now - started).components.seconds
        print("Галерея: \(Set(shots.map(\.state)).count) состояний, \(shots.count - missing.count) снимков из \(shots.count) за \(seconds) с: \(folder.path)")
        for (file, reason) in missing.sorted(by: { $0.key < $1.key }) { print("Не снято: \(file) — \(reason)") }
        if !model.saveAll() { print("Галерея: не записано при выходе, ошибка: \(model.loadError ?? "нет")") }
        NSApp.terminate(nil)
    }

    private func capture(_ shot: GalleryShot) async {
        NSApp.appearance = NSAppearance(named: shot.theme == .light ? .aqua : .darkAqua)
        let contentSize = NSSize(width: shot.size.width, height: shot.size.height)
        if let screen = window.screen {
            // Место и размер — одним вызовом: окно у нижнего края экрана, как развёрнутое. Если ставить размер
            // раньше места, система ужимает окно по краю экрана (экран 1512×982 в виртуальном Mac).
            let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
            let y = max(screen.frame.minY, min(screen.visibleFrame.minY, screen.visibleFrame.maxY - size.height))
            window.setFrame(NSRect(origin: NSPoint(x: screen.visibleFrame.minX, y: y), size: size), display: true)
        } else {
            window.setContentSize(contentSize)
        }
        await reset()
        if let problem = await show(shot.state.scene) {
            missing[shot.fileName] = problem
            return
        }
        try? await Task.sleep(for: Self.settleDelay)
        do {
            try CompositeWindowSnapshot.png(of: window).write(to: folder.appending(path: shot.fileName), options: .atomic)
        } catch {
            missing[shot.fileName] = error.localizedDescription
        }
        await tearDown(shot.state.scene)
    }

    /// Окно в исходное состояние: без меню, поповеров и подсветки, ветки «Проекты» развёрнуты, открыта страница «Буфер».
    private func reset() async {
        // Окно корзины — тоже дочернее окно: убирается вместе с меню, повторный щелчок его бы снова открыл.
        for child in window.childWindows ?? [] { child.orderOut(nil) }
        isTrashShown = false
        PageTreePreview.clearHover(in: window)
        window.makeFirstResponder(nil)
        if let buffer = model.tree.page(library.sample.page.id)?.parentId { model.select(buffer) }
        await settle()
        for pageId in library.projectBranch { PageTreePreview.setExpanded(true, page: pageId, in: window) }
    }

    /// Привести окно в состояние; вернуть причину, если не вышло.
    private func show(_ scene: GalleryScene) async -> String? {
        switch scene {
        case .samplePage(let scrolledToBottom):
            await open(library.sample.page.id)
            if scrolledToBottom { PageEditorPreview.scrollToEnd(in: window) }

        case .block(let kind, let caret):
            guard let page = library.blockKindPages[kind] else { return "нет страницы типа \(kind.rawValue)" }
            await open(page.pageId)
            switch caret {
            case .none: break
            case .inMiddle, .atEnd:
                PageEditorPreview.placeCaret(atEndOf: caret == .inMiddle ? page.emptyInMiddle : page.emptyAtEnd, in: window)
                GalleryTarget.scrollToSelection(in: window)
                if let problem = GalleryTarget.selectionProblem("курсор", in: window) { return problem }
            }

        case .emptyPage:
            await open(library.emptyPage, keepingCaret: true)

        case .untitledPage:
            await open(library.untitledPage)
            PageEditorPreview.focusTitle(in: window)

        case .nestedLists:
            await open(library.nestedLists)

        case .blockHover(let kind):
            await open(library.sample.page.id)
            guard let block = library.sampleBlock(kind), GalleryTarget.scrollToBlock(block.id, in: window),
                  PageEditorPreview.hoverBlock(block.id, in: window) else {
                return "нет блока \(kind.rawValue) в образце"
            }
            if let problem = GalleryTarget.handlesProblem("ручки блока \(kind.rawValue)", in: window) { return problem }

        case .slashMenu(let filter):
            guard let page = library.blockKindPages[.paragraph] else { return "нет страницы абзацев" }
            await open(page.pageId)
            PageEditorPreview.placeCaret(atEndOf: page.emptyInMiddle, in: window)
            GalleryTarget.scrollToSelection(in: window)
            PageEditorPreview.type("/" + filter, in: window)
            if window.childWindows?.contains(where: \.isVisible) != true { return "меню «/» не открылось" }
            if let problem = GalleryTarget.selectionProblem("курсор", in: window) ?? GalleryTarget.popupsProblem("меню «/»", in: window) {
                return problem
            }

        case .bulletByShortcutAtEnd:
            guard let page = library.blockKindPages[.bulletItem] else { return "нет страницы списка" }
            await open(page.pageId)
            // ⌫ делает последний пустой пункт абзацем, «- » — снова пунктом, как у Юрия; повторять можно.
            PageEditorPreview.placeCaret(atEndOf: page.emptyAtEnd, in: window)
            PageEditorPreview.textView(in: window)?.deleteBackward(nil)
            PageEditorPreview.type("- ", in: window)

        case .blockDragging:
            await open(library.nestedLists)
            guard PageEditorPreview.beginDrag(ofBlock: library.nestedListGroup, by: CGSize(width: 24, height: 100), in: window) else {
                return "перетаскивание не началось"
            }

        case .blockMenu:
            await open(library.sample.page.id)
            guard let block = library.sampleBlock(.heading1), GalleryTarget.scrollToBlock(block.id, in: window),
                  PageEditorPreview.openBlockMenu(forBlock: block.id, in: window) else {
                return "меню блока не открылось"
            }
            if let problem = GalleryTarget.handlesProblem("ручки блока", in: window) ?? GalleryTarget.popupsProblem("меню блока", in: window) {
                return problem
            }

        case .formattedSelection:
            await open(library.sample.page.id)
            guard let block = library.sample.blocks.first else { return "образец пуст" }
            let text = block.text.string as NSString
            let start = text.range(of: "жирный").location, end = NSMaxRange(text.range(of: "зачёркнутый"))
            guard start != NSNotFound, end <= text.length else { return "в первом абзаце нет оформления" }
            PageEditorPreview.select(NSRange(location: start, length: end - start), inBlock: block.id, in: window)
            GalleryTarget.scrollToSelection(in: window)
            if let problem = GalleryTarget.selectionProblem("выделение", in: window) { return problem }

        case .formatBar(let kindMenu):
            await open(library.sample.page.id)
            guard let block = library.sample.blocks.first else { return "образец пуст" }
            let bold = (block.text.string as NSString).range(of: "жирный")
            guard bold.location != NSNotFound else { return "в первом абзаце нет слова «жирный»" }
            PageEditorPreview.select(bold, inBlock: block.id, in: window)
            GalleryTarget.scrollToSelection(in: window)
            if kindMenu, !PageEditorPreview.openFormatBarKindMenu(in: window) { return "список типов не открылся" }
            if let problem = GalleryTarget.popupsProblem("панель форматирования", in: window) { return problem }

        case .pageIcon(let state):
            switch state {
            case .addIconHover:
                await open(library.emptyPage)
                if !PageEditorPreview.hoverHeader(in: window) { return "«Добавить иконку» не видна" }
            case .picker, .pickerSearch:
                await open(library.nestedLists)
                guard PageEditorPreview.openIconPicker(query: state == .pickerSearch ? "кот" : "", in: window) else {
                    return "окно выбора иконки не открылось"
                }
                if let problem = GalleryTarget.popupsProblem("окно выбора иконки", in: window) { return problem }
            }

        case .selectionAcrossBlocks:
            guard let page = library.blockKindPages[.numberedItem] else { return "нет страницы нумерованного списка" }
            await open(page.pageId)
            guard let textView = PageEditorPreview.textView(in: window), let first = textView.document.blocks.first?.id,
                  PageEditorPreview.selectBlocks(from: first, through: page.paragraphAfterEmpty, in: window) else {
                return "блоки не выделены"
            }
            GalleryTarget.scrollToSelection(in: window)
            if let problem = GalleryTarget.selectionProblem("выделение", in: window) { return problem }

        case .blockSelection:
            guard let page = library.blockKindPages[.numberedItem] else { return "нет страницы нумерованного списка" }
            await open(page.pageId)
            guard let textView = PageEditorPreview.textView(in: window), let first = textView.document.blocks.first?.id,
                  PageEditorPreview.selectWholeBlocks(from: first, through: page.paragraphAfterEmpty, in: window) else {
                return "блоки не выделены"
            }
            GalleryTarget.scrollToSelection(in: window)
            if let problem = GalleryTarget.selectionProblem("выделение", in: window) { return problem }

        case .softLineBreaks:
            guard let item = library.softBreaks.dropFirst().first else { return "нет блоков с переносами" }
            await open(library.softBreaksPage)
            PageEditorPreview.placeCaret(atEndOf: item, in: window)
            GalleryTarget.scrollToSelection(in: window)

        case .selectionAcrossSoftBreaks:
            guard let first = library.softBreaks.first, let last = library.softBreaks.dropFirst(2).first else { return "нет блоков с переносами" }
            await open(library.softBreaksPage)
            guard PageEditorPreview.selectBlocks(from: first, through: last, in: window) else { return "блоки не выделены" }
            GalleryTarget.scrollToSelection(in: window)
            if let problem = GalleryTarget.selectionProblem("выделение", in: window) { return problem }

        case .sidebarTree(let collapsed):
            await open(library.sample.page.id)
            if collapsed { PageTreePreview.setExpanded(false, page: library.projects, in: window) }

        case .sidebarRowHover(let longTitle):
            await open(library.sample.page.id)
            let pageId = longTitle ? library.longTitlePage : library.projects
            guard let row = PageTreePreview.row(ofPage: pageId, in: window) else { return "строки дерева нет" }
            GalleryTarget.scrollToRow(row, in: window)
            guard PageTreeHoverPreview.hoverRow(row, in: window) else { return "строки дерева не видно" }
            if let problem = GalleryTarget.rowProblem("строка дерева", row, in: window) { return problem }

        case .sidebarSelectedRow:
            await open(library.deepPage)

        case .sidebarRenaming:
            await open(library.sample.page.id)
            guard let row = PageTreePreview.row(ofPage: library.projectBranch[1], in: window) else { return "строки дерева нет" }
            GalleryTarget.scrollToRow(row, in: window)
            guard PageTreePreview.beginRenaming(page: library.projectBranch[1], in: window) else { return "строку не переименовать" }
            if let problem = GalleryTarget.rowProblem("строка дерева", row, in: window) { return problem }

        case .sidebarHidden:
            await open(library.sample.page.id)
            model.toggleSidebar()
            await settle()

        case .search(let nothingFound):
            await open(library.sample.page.id)
            model.search.type(nothingFound ? "абракадабра" : "стран")
            await settle()
            guard model.search.isShowingResults else { return "выдача поиска не открылась" }
            if let problem = GalleryTarget.popupsProblem("выдача поиска", in: window) { return problem }

        case .trash(let trash):
            await open(library.sample.page.id)
            switch trash {
            case .rowAtBottom: break
            case .open:
                await toggleTrash()
                guard isTrashShown else { return "окно корзины не открылось" }
                if let problem = GalleryTarget.popupsProblem("окно корзины", in: window) { return problem }
            case .confirmDeleteForever:
                await toggleTrash()
                guard GalleryInput.clickFirstDeleteForever() else { return "окно корзины не открылось" }
                await settle()
            case .openEmpty:
                if !model.trashEntries.isEmpty { model.emptyTrash() }
                await settle()
                await toggleTrash()
                guard isTrashShown else { return "окно корзины не открылось" }
                if let problem = GalleryTarget.popupsProblem("окно корзины", in: window) { return problem }
            }

        case .saveErrorBanner:
            await open(library.notesPage)
            PageEditorPreview.placeCaret(atEndOf: library.notesBlock, in: window)
            failingWrites.isBroken = true
            PageEditorPreview.type("!", in: window)
            model.saveAll()

        case .longBreadcrumb:
            await open(library.deepPage)

        case .notionImport(let state):
            guard let controller = AppDelegate.importController else { return "импорт из Notion не подключён" }
            await open(library.sample.page.id)
            controller.showPreview(Self.importPreview(state))
            await settle()
            if state != .progress, window.attachedSheet == nil { return "лист импорта не открылся" }
        }
        return nil
    }

    /// Убрать следы состояния, которые переживают смену страницы: набранный текст, отказ записи, диалог.
    private func tearDown(_ scene: GalleryScene) async {
        switch scene {
        case .slashMenu(let filter):
            for _ in 0...filter.count { PageEditorPreview.textView(in: window)?.deleteBackward(nil) }
        case .saveErrorBanner:
            // Стереть «!», пока диск ещё «сломан»: несохранённого не остаётся, и полоса снимается сама.
            PageEditorPreview.textView(in: window)?.deleteBackward(nil)
            failingWrites.isBroken = false
            if !model.saveAll() { print("Галерея: полоса «Изменения не сохранены» не снялась после стирания правки") }
        case .blockDragging:
            PageEditorPreview.cancelDrag(in: window)
        case .trash(.confirmDeleteForever):
            GalleryInput.pressButton(titled: "Отмена")
            await settle()
        case .sidebarHidden:
            model.toggleSidebar()
            await settle()
        case .search:
            model.search.dismiss()
        case .notionImport:
            AppDelegate.importController?.showPreview(.idle)
            await settle()
        default:
            break
        }
    }

    /// Импорт на 1 000 страниц, как у замера SC-010: в отчёте — несколько страниц с упрощениями.
    private static func importPreview(_ state: GalleryNotionImport) -> NotionImportController.State {
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 15, minute: 4))!
        switch state {
        case .progress:
            return .running(NotionImportProgress(phase: .writing, done: 420, total: 1_000))
        case .repeatWarning:
            return .confirmRepeat(previous: NotionImportRun(
                id: UUID(), sourceFingerprint: "", startedAt: date, finishedAt: date, rootPageId: nil, importedPages: 1_000,
                simplifiedItems: [], status: .finished))
        case .report:
            return .finished(NotionImportReport(
                rootPageId: UUID(), rootTitle: "Импорт из Notion — 18 октября 2026", pageCount: 1_000, blockCount: 147_400,
                simplified: [
                    SimplifiedPage(pageTitle: "Проекты", items: ["таблица", "файл или картинка ×2", "цитата", "выноска", "блок кода"]),
                    SimplifiedPage(pageTitle: "Задачи", items: ["таблица"]),
                    SimplifiedPage(pageTitle: "Идеи на 2027 год с очень длинным названием страницы", items: ["файл или картинка"]),
                    SimplifiedPage(pageTitle: "Рецепты", items: ["переключатель ×3", "разделитель"]),
                    SimplifiedPage(pageTitle: "Чтение", items: ["цитата ×12", "встраивание"]),
                ]))
        }
    }

    /// Открыть страницу заново (свой редактор) и снять курсор, который новая страница ставит в начало.
    private func open(_ pageId: UUID, keepingCaret: Bool = false) async {
        model.select(pageId)
        await settle()
        if !keepingCaret { window.makeFirstResponder(nil) }
    }

    /// Щелчок по «Корзине»; `true` — окно корзины теперь в нужном состоянии.
    @discardableResult
    private func toggleTrash() async -> Bool {
        GalleryInput.clickTrashRow(in: window)
        await settle()
        isTrashShown = GalleryInput.trashPopoverWindow != nil
        return true
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func writeReport(_ shots: [GalleryShot]) {
        do {
            try GalleryReport.manifestJSON(for: shots.filter { missing[$0.fileName] == nil })
                .write(to: folder.appending(path: "manifest.json"), options: .atomic)
            try Data(GalleryReport.indexHTML(for: shots, missing: missing).utf8)
                .write(to: folder.appending(path: "index.html"), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Галерея: опись не записана: \(error.localizedDescription)\n".utf8))
        }
    }
}

/// Отказ записи по команде галереи: для полосы «Изменения не сохранены».
final class FailingWrites: NotesWriteHook {
    private let broken = Mutex(false)

    var isBroken: Bool {
        get { broken.withLock { $0 } }
        set { broken.withLock { $0 = newValue } }
    }

    func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        if isBroken { throw DiskUnavailable() }
    }

    struct DiskUnavailable: LocalizedError {
        var errorDescription: String? { "диск недоступен" }
    }
}

/// Щелчки без мыши: события мыши отдаются окну так же, как их отдаёт система. Доступность SwiftUI здесь
/// не годится — дерево доступности строится, только когда подключён VoiceOver или другой клиент.
@MainActor
enum GalleryInput {
    /// Щелчок в точке окна (координаты окна, начало внизу слева).
    static func click(at point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            window.sendEvent(event)
        }
    }

    /// Строка «Корзина» внизу боковой панели.
    static func clickTrashRow(in window: NSWindow) {
        let point = NSPoint(x: Metrics.Sidebar.panelInset + Metrics.Sidebar.rowHorizontalPadding + 40,
                            y: Metrics.Sidebar.footerBottomInset + Metrics.Sidebar.rowHeight / 2)
        click(at: point, in: window)
    }

    /// Окно корзины, если открыто.
    static var trashPopoverWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.accessibilityIdentifier() == "trash-panel" }
    }

    /// Кнопка «Удалить навсегда» первой записи корзины: последняя кнопка справа в первой строке под заголовком.
    @discardableResult
    static func clickFirstDeleteForever() -> Bool {
        guard let panel = trashPopoverWindow, let content = panel.contentView.flatMap(hostingView) else { return false }
        let sidebar = Metrics.Sidebar.self, trash = Metrics.TrashPanel.self
        let x = content.bounds.width - trash.contentInset - sidebar.rowHorizontalPadding / 2 - sidebar.rowAccessorySize / 2
        let yFromTop = trash.contentInset + sidebar.rowHeight * 1.5
        let local = NSPoint(x: x, y: content.isFlipped ? yFromTop : content.bounds.height - yFromTop)
        click(at: content.convert(local, to: nil), in: panel)
        return true
    }

    /// Нажать кнопку диалога по надписи.
    @discardableResult
    static func pressButton(titled title: String) -> Bool {
        for window in NSApp.windows where window.isVisible {
            if let button = window.contentView.flatMap({ findButton(titled: title, in: $0) }) {
                button.performClick(nil)
                return true
            }
        }
        return false
    }

    private static func hostingView(in view: NSView) -> NSView? {
        if String(describing: type(of: view)).contains("HostingView") { return view }
        return view.subviews.lazy.compactMap(hostingView).first
    }

    private static func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { findButton(titled: title, in: $0) }.first
    }
}
