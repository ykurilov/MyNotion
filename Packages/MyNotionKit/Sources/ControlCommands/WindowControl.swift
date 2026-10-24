import ControlProtocol
import Foundation

/// Где открыть страницу (`open --new-tab`, `--new-window`).
public enum OpenPlacement: String, Sendable, Hashable, CaseIterable {
    case current, newTab, newWindow
}

public struct TabInfo: Sendable, Hashable {
    public var index: Int
    public var pageId: UUID?
    public var title: String
    public var isSelected: Bool

    public init(index: Int, pageId: UUID?, title: String, isSelected: Bool) {
        self.index = index
        self.pageId = pageId
        self.title = title
        self.isSelected = isSelected
    }
}

public struct WindowInfo: Sendable, Hashable {
    /// С 1, по порядку окон на экране.
    public var index: Int
    public var isFront: Bool
    public var tabs: [TabInfo]
    public var canGoBack: Bool
    public var canGoForward: Bool
    /// Открыт лист или диалог: команды окна отвечают `window_busy`.
    public var isBusy: Bool
    /// У окна есть закрытая вкладка, которую вернёт `tab reopen`.
    public var canReopenTab: Bool

    public init(index: Int, isFront: Bool, tabs: [TabInfo], canGoBack: Bool, canGoForward: Bool, isBusy: Bool, canReopenTab: Bool = false) {
        self.index = index
        self.isFront = isFront
        self.tabs = tabs
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isBusy = isBusy
        self.canReopenTab = canReopenTab
    }
}

/// Окна и вкладки приложения (data-model.md, «Окно»). Реализация — `App/Control/AppWindowControl.swift`, в тестах —
/// подставная. Номера окон и вкладок команда уже проверила по `windows()`: сюда приходят существующие (`window` — всегда
/// номер окна, кроме `open` в новое окно). Окна на передний план сами не выходят: только `open --activate`.
@MainActor
public protocol WindowControl: AnyObject {
    /// Страница передней вкладки переднего окна (`current` в указателе страницы).
    var currentPageId: UUID? { get }
    func windows() -> [WindowInfo]
    /// Открыть страницу; для нового окна ждёт, пока оно появится.
    func open(_ pageId: UUID, placement: OpenPlacement, blockId: UUID?, window: Int?, activate: Bool) async throws -> WindowInfo
    func newTab(window: Int) throws -> WindowInfo
    func selectTab(_ tab: Int, window: Int) throws -> WindowInfo
    func closeTab(_ tab: Int, window: Int) throws -> WindowInfo
    func reopenTab(window: Int) throws -> WindowInfo
    func back(window: Int) throws -> WindowInfo
    func forward(window: Int) throws -> WindowInfo
}

extension WindowControl {
    public func open(_ pageId: UUID, placement: OpenPlacement, blockId: UUID?, window: Int?, activate: Bool) async throws -> WindowInfo {
        throw ControlError.notImplemented(stage: 6)
    }

    public func newTab(window: Int) throws -> WindowInfo { throw ControlError.notImplemented(stage: 6) }
    public func selectTab(_ tab: Int, window: Int) throws -> WindowInfo { throw ControlError.notImplemented(stage: 6) }
    public func closeTab(_ tab: Int, window: Int) throws -> WindowInfo { throw ControlError.notImplemented(stage: 6) }
    public func reopenTab(window: Int) throws -> WindowInfo { throw ControlError.notImplemented(stage: 6) }
    public func back(window: Int) throws -> WindowInfo { throw ControlError.notImplemented(stage: 6) }
    public func forward(window: Int) throws -> WindowInfo { throw ControlError.notImplemented(stage: 6) }
}

extension ControlError {
    /// Команда каталога, чей обработчик появится на этапе `stage` 005.
    public static func notImplemented(stage: Int, command: String? = nil) -> ControlError {
        ControlError(.notImplemented, (command.map { "Команда «\($0)» " } ?? "Команда ") + "ещё не готова: этап \(stage) фичи 005",
                     hint: "Что уже работает: mynotion commands --json (поле stage)", details: ["stage": .number(Double(stage))])
    }
}
