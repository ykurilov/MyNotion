import AppKit
import ControlCommands
import ControlProtocol
import Foundation
import Navigation
import NotesCore

/// Окна и вкладки для команд поверх тех же моделей, что ⌘T, ⌘[, ⌘] и ⌘N (research R12). Номера окон и вкладок команда
/// уже проверила по `windows()`. Окна вперёд сами не выходят: без `--activate` окно только поднимается над другими
/// (`orderFront`), приложение не становится активным.
@MainActor
final class AppWindowControl: WindowControl {
    /// Сколько ждать появления нового окна: SwiftUI создаёт его на следующих проходах цикла событий.
    private static let newWindowTimeout: Duration = .seconds(5)

    private unowned let library: PagesLibrary

    init(library: PagesLibrary) {
        self.library = library
    }

    var currentPageId: UUID? { library.activeWindow?.openPageId }

    func windows() -> [WindowInfo] {
        library.windowModels.enumerated().map { info(of: $1, index: $0 + 1) }
    }

    func open(_ pageId: UUID, placement: OpenPlacement, blockId: UUID?, window: Int?, activate: Bool) async throws -> WindowInfo {
        let model: MainWindowModel
        switch placement {
        case .newWindow:
            model = try await newWindowModel(opening: pageId)
        case .current, .newTab:
            model = try existingModel(window)
        }
        // Строка базы открывается на всю страницу: просмотр сбоку закрыт.
        model.closeRowPeek()
        if placement == .newTab { model.openInNewTab(pageId) }
        // В только что созданном окне страница уже открыта: остаётся перейти к блоку (или, для строки базы, открыть её).
        model.open(PageOpenRequest(pageId: pageId, revealBlockId: blockId))
        present(model, activate: activate)
        return info(of: model)
    }

    func newTab(window: Int) throws -> WindowInfo {
        let model = try existingModel(window)
        model.isNewTabSearchShown = false
        model.tabs.openEmptyTab()
        model.showActiveTab(focus: .body)
        return info(of: model)
    }

    func selectTab(_ tab: Int, window: Int) throws -> WindowInfo {
        let model = try existingModel(window)
        try requireTab(tab, in: model)
        model.activateTab(tab - 1)
        return info(of: model)
    }

    func closeTab(_ tab: Int, window: Int) throws -> WindowInfo {
        let model = try existingModel(window)
        try requireTab(tab, in: model)
        model.closeTab(at: tab - 1)
        return info(of: model)
    }

    func reopenTab(window: Int) throws -> WindowInfo {
        let model = try existingModel(window)
        guard model.hasClosedTabs else {
            throw ControlError(.tabNotFound, "В окне \(window) нет закрытых вкладок", hint: "Закрытые вкладки помнятся, пока окно открыто: mynotion window state")
        }
        model.reopenClosedTab()
        return info(of: model)
    }

    func back(window: Int) throws -> WindowInfo {
        let model = try existingModel(window)
        model.goBack()
        return info(of: model)
    }

    func forward(window: Int) throws -> WindowInfo {
        let model = try existingModel(window)
        model.goForward()
        return info(of: model)
    }

    // MARK: Окна

    /// Окно по номеру (`nil` — то, где работают сейчас).
    private func existingModel(_ index: Int?) throws -> MainWindowModel {
        let models = library.windowModels
        if let index {
            guard models.indices.contains(index - 1) else {
                throw ControlError(.windowNotFound, "Окна \(index) нет: сейчас окон — \(models.count)", hint: "Номера окон: mynotion window state")
            }
            return models[index - 1]
        }
        guard let model = library.activeWindow else {
            throw ControlError(.windowNotFound, "Окон нет", hint: "Открыть страницу в новом окне: mynotion open <страница>")
        }
        return model
    }

    private func requireTab(_ tab: Int, in model: MainWindowModel) throws {
        guard model.tabs.items.indices.contains(tab - 1) else {
            throw ControlError(.tabNotFound, "Вкладки \(tab) нет: их \(model.tabs.items.count)", hint: "Номера вкладок: mynotion window state")
        }
    }

    /// Новое окно с этой страницей, как ⌘N. Окон ещё нет (приложение только запускается) — окно, которое вот-вот
    /// покажет сцена, и есть новое.
    private func newWindowModel(opening pageId: UUID) async throws -> MainWindowModel {
        let known = Set(library.windowModels.map { ObjectIdentifier($0) })
        if library.windowModels.isEmpty, library.openNewWindow == nil {
            return try await appearedWindow(excluding: known, requiringWindow: false)
        }
        guard let openNewWindow = library.openNewWindow else {
            throw ControlError(.internal, "Сцена окон приложения ещё не готова", hint: "Повторить команду через секунду")
        }
        library.pageForNextNewWindow = pageId
        openNewWindow()
        do {
            return try await appearedWindow(excluding: known, requiringWindow: true)
        } catch {
            library.pageForNextNewWindow = nil
            throw error
        }
    }

    /// Ждёт модель, которой не было в `known`, и (если нужно) её окно на экране.
    private func appearedWindow(excluding known: Set<ObjectIdentifier>, requiringWindow: Bool) async throws -> MainWindowModel {
        let deadline = ContinuousClock.now + Self.newWindowTimeout
        while ContinuousClock.now < deadline {
            if let model = library.windowModels.first(where: { !known.contains(ObjectIdentifier($0)) }), !requiringWindow || model.window != nil {
                return model
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ControlError(.timeout, "Окно не открылось за \(Self.newWindowTimeout.components.seconds) с", hint: "Проверить окна: mynotion window state")
    }

    /// Поднять окно над другими; вывести приложение вперёд — только по просьбе.
    private func present(_ model: MainWindowModel, activate: Bool) {
        guard let window = model.window else { return }
        if activate {
            NSApp.activate()
            // С macOS 14 приложение в фоне вперёд само не выходит, пока другое не уступит. Просьба через систему (как
            // `open -a`) выполняется: приложение уже запущено, оно только выходит вперёд.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    // MARK: Сведения об окне

    private func info(of model: MainWindowModel) -> WindowInfo {
        let index = library.windowModels.firstIndex { $0 === model } ?? 0
        return info(of: model, index: index + 1)
    }

    private func info(of model: MainWindowModel, index: Int) -> WindowInfo {
        let titles = model.tabStripItems.map(\.title)
        let tabs = model.tabs.items.enumerated().map { offset, tab in
            TabInfo(index: offset + 1, pageId: tab.pageId, title: titles.indices.contains(offset) ? titles[offset] : "",
                    isSelected: offset == model.tabs.activeIndex)
        }
        let isBusy = model.window?.attachedSheet != nil || model.isSyncSettingsShown || model.isNewTabSearchShown
        return WindowInfo(index: index, isFront: model === library.activeWindow, tabs: tabs, canGoBack: model.canGoBack,
                          canGoForward: model.canGoForward, isBusy: isBusy, canReopenTab: model.hasClosedTabs)
    }
}
