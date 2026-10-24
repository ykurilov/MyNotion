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

    public init(index: Int, isFront: Bool, tabs: [TabInfo], canGoBack: Bool, canGoForward: Bool, isBusy: Bool) {
        self.index = index
        self.isFront = isFront
        self.tabs = tabs
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isBusy = isBusy
    }
}

/// Окна и вкладки приложения (data-model.md, «Окно»). Реализация — `App/Control/AppWindowControl.swift`, в тестах —
/// подставная. Команды окна (этап 6) — с заглушками `not_implemented`, пока этап не реализует их у приложения.
@MainActor
public protocol WindowControl: AnyObject {
    /// Страница передней вкладки переднего окна (`current` в указателе страницы).
    var currentPageId: UUID? { get }
    func windows() -> [WindowInfo]
    /// `window` — номер окна (`nil` — переднее).
    func open(_ pageId: UUID, placement: OpenPlacement, blockId: UUID?, window: Int?, activate: Bool) throws -> WindowInfo
    func newTab(window: Int?, activate: Bool) throws -> WindowInfo
    func selectTab(_ tab: Int, window: Int?, activate: Bool) throws -> WindowInfo
    func closeTab(_ tab: Int?, window: Int?) throws -> WindowInfo
    func reopenTab(window: Int?, activate: Bool) throws -> WindowInfo
    func back(window: Int?) throws -> WindowInfo
    func forward(window: Int?) throws -> WindowInfo
}

extension WindowControl {
    public func open(_ pageId: UUID, placement: OpenPlacement, blockId: UUID?, window: Int?, activate: Bool) throws -> WindowInfo {
        throw ControlError.notImplemented(stage: 6)
    }

    public func newTab(window: Int?, activate: Bool) throws -> WindowInfo { throw ControlError.notImplemented(stage: 6) }
    public func selectTab(_ tab: Int, window: Int?, activate: Bool) throws -> WindowInfo { throw ControlError.notImplemented(stage: 6) }
    public func closeTab(_ tab: Int?, window: Int?) throws -> WindowInfo { throw ControlError.notImplemented(stage: 6) }
    public func reopenTab(window: Int?, activate: Bool) throws -> WindowInfo { throw ControlError.notImplemented(stage: 6) }
    public func back(window: Int?) throws -> WindowInfo { throw ControlError.notImplemented(stage: 6) }
    public func forward(window: Int?) throws -> WindowInfo { throw ControlError.notImplemented(stage: 6) }
}

/// Импорт, выгрузка и синхронизация приложения (этап 7): `App/Control/AppTransferControl.swift`.
@MainActor
public protocol TransferControl: AnyObject {
    /// Идёт импорт (`app status`).
    var isImporting: Bool { get }
}

extension ControlError {
    /// Команда каталога, чей обработчик появится на этапе `stage` 005.
    public static func notImplemented(stage: Int, command: String? = nil) -> ControlError {
        ControlError(.notImplemented, (command.map { "Команда «\($0)» " } ?? "Команда ") + "ещё не готова: этап \(stage) фичи 005",
                     hint: "Что уже работает: mynotion commands --json (поле stage)", details: ["stage": .number(Double(stage))])
    }
}
