import ControlProtocol
import Foundation
import NotesCore
import Testing
@testable import ControlCommands

/// Щелчок по ссылке `mynotion://page/<id>` снаружи: приложение выходит вперёд и показывает страницу через ту же команду
/// `open`; что не вышло — одной фразой для человека, без подсказок для командной строки.
@MainActor @Suite struct PageAddressOpeningTests {
    let host: TestHost
    let page: Page
    let other: Page

    init() throws {
        host = try TestHost()
        page = try host.page("Встреча", texts: ["первый", "второй"])
        other = try host.page("Другая")
    }

    func window(_ index: Int, front: Bool = true, tabs: [UUID?], selected: Int = 1, busy: Bool = false) -> WindowInfo {
        WindowInfo(index: index, isFront: front,
                   tabs: tabs.enumerated().map { TabInfo(index: $0.offset + 1, pageId: $0.element, title: "", isSelected: $0.offset + 1 == selected) },
                   canGoBack: false, canGoForward: false, isBusy: busy)
    }

    func open(_ url: String, windows: [WindowInfo]) async throws -> (problem: String?, calls: [RecordingWindowControl.Call]) {
        let control = RecordingWindowControl(windows)
        let executor = CommandExecutor(host: WindowTestHost(base: host, control: control), log: RecordingLog())
        let problem = await executor.openPageAddress(try #require(URL(string: url)))
        return (problem, control.calls)
    }

    func link(_ id: UUID, block: UUID? = nil) -> String { PageAddress(pageId: id, blockId: block).text }

    @Test func opensInNewTabOfFrontWindowAndActivates() async throws {
        let (problem, calls) = try await open(link(page.id), windows: [window(1, front: false, tabs: [other.id]), window(2, tabs: [other.id])])
        #expect(problem == nil)
        #expect(calls == [.open(page: page.id, placement: .newTab, block: nil, window: 2, activate: true)])
    }

    @Test func pageAlreadyShownStaysInItsTab() async throws {
        let (problem, calls) = try await open(link(page.id), windows: [window(1, tabs: [other.id, page.id], selected: 2)])
        #expect(problem == nil)
        #expect(calls == [.open(page: page.id, placement: .current, block: nil, window: 1, activate: true)])
    }

    @Test func withoutWindowsOpensNewWindow() async throws {
        let (problem, calls) = try await open(link(page.id), windows: [])
        #expect(problem == nil)
        #expect(calls == [.open(page: page.id, placement: .newWindow, block: nil, window: nil, activate: true)])
    }

    @Test func busyFrontWindowOpensNewWindow() async throws {
        let (problem, calls) = try await open(link(page.id), windows: [window(1, tabs: [other.id], busy: true)])
        #expect(problem == nil)
        #expect(calls == [.open(page: page.id, placement: .newWindow, block: nil, window: nil, activate: true)])
    }

    @Test func blockAddressScrollsToBlock() async throws {
        let block = try #require(try host.store.pageContent(page.id)?.blocks.last)
        let (problem, calls) = try await open(link(page.id, block: block.id), windows: [window(1, tabs: [other.id])])
        #expect(problem == nil)
        #expect(calls == [.open(page: page.id, placement: .newTab, block: block.id, window: 1, activate: true)])
    }

    @Test func goneBlockStillOpensPage() async throws {
        let (problem, calls) = try await open(link(page.id, block: UUID()), windows: [window(1, tabs: [other.id])])
        #expect(problem == nil)
        #expect(calls == [.open(page: page.id, placement: .newTab, block: nil, window: 1, activate: true)])
    }

    @Test func trashedPageExplainsInPlainWords() async throws {
        let child = try host.page("Черновик", parent: page.id)
        try PageTreeOperations(store: host.store).moveToTrash(page.id)
        for id in [page.id, child.id] {
            let (problem, calls) = try await open(link(id), windows: [window(1, tabs: [other.id])])
            #expect(calls.isEmpty)
            let text = try #require(problem)
            #expect(text.contains("корзин"))
            #expect(!text.contains("mynotion"))
        }
    }

    @Test func missingPageExplainsInPlainWords() async throws {
        let (problem, calls) = try await open(link(UUID()), windows: [window(1, tabs: [other.id])])
        #expect(calls.isEmpty)
        let text = try #require(problem)
        #expect(text.contains("не найдена"))
        #expect(!text.contains("mynotion"))
    }

    @Test func notPageAddressExplains() async throws {
        let (problem, calls) = try await open("mynotion://settings", windows: [window(1, tabs: [other.id])])
        #expect(calls.isEmpty)
        #expect(problem != nil)
    }
}
