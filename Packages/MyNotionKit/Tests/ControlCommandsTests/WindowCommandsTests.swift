import Attachments
import ControlProtocol
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore
@testable import PageVersions

/// Подставное окно приложения: хранит заданное состояние окон и записывает, что у него просили.
@MainActor
final class RecordingWindowControl: WindowControl {
    enum Call: Equatable {
        case open(page: UUID, placement: OpenPlacement, block: UUID?, window: Int?, activate: Bool)
        case newTab(window: Int)
        case selectTab(Int, window: Int)
        case closeTab(Int, window: Int)
        case reopenTab(window: Int)
        case back(window: Int)
        case forward(window: Int)
    }

    var state: [WindowInfo]
    private(set) var calls: [Call] = []

    init(_ state: [WindowInfo]) {
        self.state = state
    }

    var currentPageId: UUID? { state.first { $0.isFront }?.tabs.first { $0.isSelected }?.pageId }
    func windows() -> [WindowInfo] { state }

    func open(_ pageId: UUID, placement: OpenPlacement, blockId: UUID?, window: Int?, activate: Bool) async throws -> WindowInfo {
        calls.append(.open(page: pageId, placement: placement, block: blockId, window: window, activate: activate))
        return answer(window ?? state.count + 1)
    }

    func newTab(window: Int) throws -> WindowInfo { calls.append(.newTab(window: window)); return answer(window) }
    func selectTab(_ tab: Int, window: Int) throws -> WindowInfo { calls.append(.selectTab(tab, window: window)); return answer(window) }
    func closeTab(_ tab: Int, window: Int) throws -> WindowInfo { calls.append(.closeTab(tab, window: window)); return answer(window) }
    func reopenTab(window: Int) throws -> WindowInfo { calls.append(.reopenTab(window: window)); return answer(window) }
    func back(window: Int) throws -> WindowInfo { calls.append(.back(window: window)); return answer(window) }
    func forward(window: Int) throws -> WindowInfo { calls.append(.forward(window: window)); return answer(window) }

    private func answer(_ index: Int) -> WindowInfo {
        state.first { $0.index == index } ?? WindowInfo(index: index, isFront: true, tabs: [], canGoBack: false, canGoForward: false, isBusy: false)
    }
}

/// Хост на временной базе, но с подставным окном приложения.
@MainActor
final class WindowTestHost: ControlHost {
    let base: TestHost
    let control: RecordingWindowControl

    init(base: TestHost, control: RecordingWindowControl) {
        self.base = base
        self.control = control
    }

    var store: NotesStore { base.store }
    var attachments: AttachmentStore { base.attachments }
    var openDocuments: OpenDocuments { base.openDocuments }
    var versions: PageVersionStore { base.versions }
    var versionRecorder: PageVersionRecorder { base.versionRecorder }
    var windowControl: any WindowControl { control }
    var transferControl: (any TransferControl)? { nil }
    var appInfo: AppInfo { base.appInfo }
    var now: Date { base.now }
    func treeDidChange(_ pageIds: Set<UUID>) { base.treeDidChange(pageIds) }
    func refreshAfterDirectWrite(pages: Set<UUID>) { base.refreshAfterDirectWrite(pages: pages) }
}

@MainActor @Suite struct WindowCommandsTests {
    let host: TestHost
    let page: Page
    let other: Page
    let note: Page

    init() throws {
        host = try TestHost()
        page = try host.page("Встреча", texts: ["первый", "второй"])
        other = try host.page("Другая", texts: ["чужой блок"])
        note = try host.page("Заметка")
    }

    /// Окно с вкладками-страницами; выбрана вторая, если страниц больше одной.
    func window(_ index: Int, front: Bool = true, tabs: [UUID?], selected: Int = 1, back: Bool = false, forward: Bool = false,
                busy: Bool = false, canReopen: Bool = false) -> WindowInfo {
        WindowInfo(index: index, isFront: front,
                   tabs: tabs.enumerated().map { TabInfo(index: $0.offset + 1, pageId: $0.element, title: "В\($0.offset + 1)", isSelected: $0.offset + 1 == selected) },
                   canGoBack: back, canGoForward: forward, isBusy: busy, canReopenTab: canReopen)
    }

    func run(_ command: String, _ args: [String: ControlJSON] = [:], windows: [WindowInfo]) async -> (ControlResponse, RecordingWindowControl) {
        let control = RecordingWindowControl(windows)
        let executor = CommandExecutor(host: WindowTestHost(base: host, control: control), log: RecordingLog())
        return (await executor.run(ControlRequest(command: command, args: args)), control)
    }

    var one: [WindowInfo] { [window(1, tabs: [page.id, other.id])] }

    // MARK: window state

    @Test func stateListsWindowsAndTabs() async throws {
        let (response, control) = await run("window.state", windows: [window(1, front: false, tabs: [page.id]),
                                                                       window(2, tabs: [other.id, nil], selected: 2, back: true, canReopen: true)])
        #expect(response.ok, "\(String(describing: response.error))")
        let windows = try #require(response.data?["windows"]?.array)
        #expect(windows.count == 2)
        #expect(response.data?["front"] == 2)
        let second = windows[1]
        #expect(second["front"] == true)
        #expect(second["canGoBack"] == true)
        #expect(second["canReopenTab"] == true)
        #expect(second["tabs"]?[0]?["pageId"]?.string == other.id.controlText)
        #expect(second["tabs"]?[1]?["pageId"] == .null)
        #expect(second["tabs"]?[1]?["selected"] == true)
        #expect(control.calls.isEmpty)
    }

    @Test func stateWithoutWindows() async {
        let (response, _) = await run("window.state", windows: [])
        #expect(response.ok)
        #expect(response.data?["windows"]?.array?.isEmpty == true)
        #expect(response.data?["front"] == .null)
    }

    // MARK: open

    @Test func openInCurrentTabOfFrontWindow() async throws {
        let (response, control) = await run("open", ["page": .string(page.id.controlText)],
                                            windows: [window(1, front: false, tabs: [other.id]), window(2, tabs: [other.id])])
        #expect(response.ok, "\(String(describing: response.error))")
        #expect(control.calls == [.open(page: page.id, placement: .current, block: nil, window: 2, activate: false)])
        #expect(response.data?["page"]?["id"]?.string == page.id.controlText)
        #expect(response.data?["window"]?["index"] == 2)
    }

    @Test func openByPath() async {
        let (response, control) = await run("open", ["page": "Встреча"], windows: one)
        #expect(response.ok)
        #expect(control.calls == [.open(page: page.id, placement: .current, block: nil, window: 1, activate: false)])
    }

    @Test func openInNewTab() async {
        let (response, control) = await run("open", ["page": .string(page.id.controlText), "newTab": true], windows: one)
        #expect(response.ok)
        #expect(control.calls == [.open(page: page.id, placement: .newTab, block: nil, window: 1, activate: false)])
    }

    @Test func openInNewWindowKeepsExistingWindowsUntouched() async {
        let (response, control) = await run("open", ["page": .string(page.id.controlText), "newWindow": true], windows: one)
        #expect(response.ok)
        #expect(control.calls == [.open(page: page.id, placement: .newWindow, block: nil, window: nil, activate: false)])
        #expect(response.data?["window"]?["index"] == 2)
    }

    @Test func openWithoutWindowsMakesNewWindow() async {
        for flags: [String: ControlJSON] in [[:], ["newTab": true]] {
            let (response, control) = await run("open", ["page": .string(page.id.controlText)].merging(flags) { $1 }, windows: [])
            #expect(response.ok, "\(String(describing: response.error))")
            #expect(control.calls == [.open(page: page.id, placement: .newWindow, block: nil, window: nil, activate: false)])
        }
    }

    @Test func openActivateIsExplicit() async {
        let (response, control) = await run("open", ["page": .string(page.id.controlText), "activate": true], windows: one)
        #expect(response.ok)
        #expect(control.calls == [.open(page: page.id, placement: .current, block: nil, window: 1, activate: true)])
    }

    @Test func openWithBlockPassesBlockOfThatPage() async throws {
        let block = try #require(try host.store.pageContent(page.id)?.blocks.last)
        let (response, control) = await run("open", ["page": .string(page.id.controlText), "block": .string(block.id.controlText)], windows: one)
        #expect(response.ok, "\(String(describing: response.error))")
        #expect(control.calls == [.open(page: page.id, placement: .current, block: block.id, window: 1, activate: false)])
    }

    @Test func openWithBlockOfAnotherPageRefused() async throws {
        let block = try #require(try host.store.pageContent(other.id)?.blocks.first)
        let (response, control) = await run("open", ["page": .string(page.id.controlText), "block": .string(block.id.controlText)], windows: one)
        #expect(response.error?.code == .wrongPage)
        #expect(control.calls.isEmpty)
    }

    @Test func openTrashedPageRefusedWithoutIncludeTrashed() async throws {
        try host.store.write { tx in
            var trashed = try tx.page(note.id)!
            trashed.trashedAt = Date()
            try tx.updatePage(trashed)
        }
        let (response, control) = await run("open", ["page": .string(note.id.controlText)], windows: one)
        #expect(response.error?.code == .pageInTrash)
        #expect(control.calls.isEmpty)
    }

    @Test func openUnknownPage() async {
        let (response, control) = await run("open", ["page": "Нет такой"], windows: one)
        #expect(response.error?.code == .pageNotFound)
        #expect(control.calls.isEmpty)
    }

    @Test func newTabAndNewWindowTogetherRefused() async {
        let (response, control) = await run("open", ["page": .string(page.id.controlText), "newTab": true, "newWindow": true], windows: one)
        #expect(response.error?.code == .invalidArgument)
        #expect(control.calls.isEmpty)
    }

    // MARK: Лист открыт

    @Test func busyWindowRefusesOpenInIt() async {
        let busy = [window(1, tabs: [page.id], busy: true)]
        for flags: [String: ControlJSON] in [[:], ["newTab": true]] {
            let (response, control) = await run("open", ["page": .string(other.id.controlText)].merging(flags) { $1 }, windows: busy)
            #expect(response.error?.code == .windowBusy, "\(flags)")
            #expect(control.calls.isEmpty)
        }
    }

    @Test func busyWindowDoesNotStopNewWindow() async {
        let (response, control) = await run("open", ["page": .string(other.id.controlText), "newWindow": true],
                                            windows: [window(1, tabs: [page.id], busy: true)])
        #expect(response.ok)
        #expect(control.calls.count == 1)
    }

    @Test func busyWindowRefusesTabAndNavCommands() async {
        let busy = [window(1, tabs: [page.id, other.id], back: true, forward: true, busy: true, canReopen: true)]
        let commands: [(String, [String: ControlJSON])] = [
            ("tab.new", [:]), ("tab.select", ["tab": 2]), ("tab.close", ["tab": 2]), ("tab.reopen", [:]), ("nav.back", [:]), ("nav.forward", [:]),
        ]
        for (command, args) in commands {
            let (response, control) = await run(command, args, windows: busy)
            #expect(response.error?.code == .windowBusy, "\(command)")
            #expect(control.calls.isEmpty, "\(command)")
        }
    }

    @Test func stateAnswersEvenWhenWindowBusy() async {
        let (response, _) = await run("window.state", windows: [window(1, tabs: [page.id], busy: true)])
        #expect(response.ok)
        #expect(response.data?["windows"]?[0]?["busy"] == true)
    }

    // MARK: tab

    @Test func newTabInFrontWindowOrNamedOne() async {
        let two = [window(1, front: false, tabs: [page.id]), window(2, tabs: [other.id])]
        let (front, frontControl) = await run("tab.new", windows: two)
        #expect(front.ok)
        #expect(frontControl.calls == [.newTab(window: 2)])
        let (named, namedControl) = await run("tab.new", ["window": 1], windows: two)
        #expect(named.ok)
        #expect(namedControl.calls == [.newTab(window: 1)])
        #expect(named.data?["window"]?["index"] == 1)
    }

    @Test func selectTab() async {
        let (response, control) = await run("tab.select", ["tab": 2], windows: one)
        #expect(response.ok)
        #expect(control.calls == [.selectTab(2, window: 1)])
    }

    @Test func selectMissingTab() async {
        for number in [0, 3, -1] {
            let (response, control) = await run("tab.select", ["tab": .number(Double(number))], windows: one)
            #expect(response.error?.code == .tabNotFound, "\(number)")
            #expect(control.calls.isEmpty)
        }
    }

    @Test func tabSelectNeedsNumber() async {
        let (response, _) = await run("tab.select", windows: one)
        #expect(response.error?.code == .missingArgument)
    }

    @Test func closeTabByNumberOrSelected() async {
        let (byNumber, byNumberControl) = await run("tab.close", ["tab": 2], windows: [window(1, tabs: [page.id, other.id, note.id], selected: 3)])
        #expect(byNumber.ok)
        #expect(byNumberControl.calls == [.closeTab(2, window: 1)])
        let (selected, selectedControl) = await run("tab.close", windows: [window(1, tabs: [page.id, other.id, note.id], selected: 3)])
        #expect(selected.ok)
        #expect(selectedControl.calls == [.closeTab(3, window: 1)])
    }

    @Test func closeMissingTab() async {
        let (response, control) = await run("tab.close", ["tab": 9], windows: one)
        #expect(response.error?.code == .tabNotFound)
        #expect(control.calls.isEmpty)
    }

    @Test func lastTabOfWindowIsNotClosed() async {
        let (response, control) = await run("tab.close", windows: [window(1, tabs: [page.id], selected: 1)])
        #expect(response.error?.code == .invalidArgument)
        #expect(response.error?.hint?.isEmpty == false)
        #expect(control.calls.isEmpty)
    }

    @Test func reopenTab() async {
        let (response, control) = await run("tab.reopen", windows: [window(1, tabs: [page.id], canReopen: true)])
        #expect(response.ok)
        #expect(control.calls == [.reopenTab(window: 1)])
    }

    @Test func reopenWithoutClosedTabs() async {
        let (response, control) = await run("tab.reopen", windows: one)
        #expect(response.error?.code == .tabNotFound)
        #expect(control.calls.isEmpty)
    }

    @Test func missingWindow() async {
        for command in ["tab.new", "tab.reopen", "nav.back", "nav.forward"] {
            let (response, control) = await run(command, ["window": 5], windows: one)
            #expect(response.error?.code == .windowNotFound, "\(command)")
            #expect(control.calls.isEmpty)
        }
    }

    @Test func tabCommandsWithoutWindows() async {
        let (response, control) = await run("tab.new", windows: [])
        #expect(response.error?.code == .windowNotFound)
        #expect(response.error?.hint?.contains("open") == true)
        #expect(control.calls.isEmpty)
    }

    // MARK: nav

    @Test func navBackAndForward() async throws {
        let history = [window(1, tabs: [page.id], back: true, forward: true)]
        let (back, backControl) = await run("nav.back", windows: history)
        #expect(back.ok)
        #expect(backControl.calls == [.back(window: 1)])
        #expect(back.data?["moved"] == true)
        let (forward, forwardControl) = await run("nav.forward", ["window": 1], windows: history)
        #expect(forward.ok)
        #expect(forwardControl.calls == [.forward(window: 1)])
    }

    @Test func navWithNowhereToGoIsHarmless() async {
        let (back, backControl) = await run("nav.back", windows: one)
        #expect(back.ok)
        #expect(back.data?["moved"] == false)
        #expect(backControl.calls.isEmpty)
        let (forward, forwardControl) = await run("nav.forward", windows: one)
        #expect(forward.ok)
        #expect(forward.data?["moved"] == false)
        #expect(forwardControl.calls.isEmpty)
    }

    // MARK: Пакет

    @Test func windowCommandsAreNotBatchable() async {
        for (command, args) in [("open", ["page": ControlJSON.string("Встреча")]), ("tab new", [:]), ("tab select", ["tab": 1]), ("tab close", [:]),
                                ("tab reopen", [:]), ("nav back", [:]), ("nav forward", [:])] as [(String, [String: ControlJSON])] {
            let (response, control) = await run("batch", ["steps": [["command": .string(command), "args": .object(args)]]], windows: one)
            #expect(response.error?.code == .notBatchable, "\(command)")
            #expect(control.calls.isEmpty)
        }
    }
}
