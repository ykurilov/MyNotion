import Attachments
import ControlProtocol
import Foundation
import NotesCore
import PageVersions
import Testing
@testable import ControlCommands

/// Ссылки как у окна «Поделиться»: подставной контроллер, у которого повторное включение даёт ту же ссылку.
@MainActor
final class RecordingShareControl: ShareControl {
    var isAvailable = true
    private(set) var links: [UUID: ShareLinkState] = [:]
    private var counter = 0

    private func newURL() -> URL {
        counter += 1
        return URL(string: "https://notes.example/s/token\(counter)")!
    }

    func shareLink(of pageId: UUID) async throws -> ShareLinkState? { links[pageId] }

    func setShareLink(of pageId: UUID, enabled: Bool, includeSubpages: Bool?) async throws -> ShareLinkState {
        let old = links[pageId]
        let state = ShareLinkState(url: old?.url ?? newURL(), enabled: enabled, includeSubpages: includeSubpages ?? old?.includeSubpages ?? true,
                                   isPublished: enabled)
        links[pageId] = state
        return state
    }

    func rotateShareLink(of pageId: UUID) async throws -> ShareLinkState {
        var state = try #require(links[pageId])
        state.url = newURL()
        links[pageId] = state
        return state
    }
}

@MainActor
final class ShareTestHost: ControlHost {
    let base: TestHost
    let shares = RecordingShareControl()

    init() throws {
        base = try TestHost()
    }

    var store: NotesStore { base.store }
    var attachments: AttachmentStore { base.attachments }
    var openDocuments: OpenDocuments { base.openDocuments }
    var versions: PageVersionStore { base.versions }
    var versionRecorder: PageVersionRecorder { base.versionRecorder }
    var windowControl: any WindowControl { base.windowControl }
    var transferControl: (any TransferControl)? { nil }
    var shareControl: (any ShareControl)? { shares }
    var appInfo: AppInfo { base.appInfo }
    var now: Date { base.now }
    func treeDidChange(_ pageIds: Set<UUID>) { base.treeDidChange(pageIds) }
    func refreshAfterDirectWrite(pages: Set<UUID>) { base.refreshAfterDirectWrite(pages: pages) }
}

@MainActor @Suite struct ShareCommandsTests {
    let host: ShareTestHost
    let executor: CommandExecutor

    init() throws {
        host = try ShareTestHost()
        executor = CommandExecutor(host: host, log: RecordingLog())
    }

    private func share(_ tokens: [String]) async throws -> ControlResponse {
        let spec = try #require(CommandCatalog.all.first { $0.name == "page.share" })
        let args = try ArgumentParser.parse(tokens, for: spec) { $0 }
        return await executor.run(ControlRequest(command: "page.share", args: args))
    }

    @Test("on — ссылка с подстраницами; off и снова on — та же ссылка; rotate — новая; show — как есть")
    func onOffRotateShow() async throws {
        let page = try host.base.page("Отчёт")
        #expect(try await share(["show", page.id.controlText]).data?["enabled"]?.bool == false)

        let on = try await share(["on", page.id.controlText])
        #expect(on.ok)
        #expect(on.data?["enabled"]?.bool == true)
        #expect(on.data?["includeSubpages"]?.bool == true)
        let url = try #require(on.data?["url"]?.string)

        #expect(try await share(["off", page.id.controlText]).data?["enabled"]?.bool == false)
        let again = try await share(["on", page.id.controlText, "--subpages", "off"])
        #expect(again.data?["url"]?.string == url)
        #expect(again.data?["includeSubpages"]?.bool == false)

        let rotated = try await share(["rotate", page.id.controlText])
        #expect(rotated.data?["url"]?.string != url)
        #expect(try await share(["show", page.id.controlText]).data?["url"]?.string == rotated.data?["url"]?.string)
    }

    @Test("Без синхронизации — sync_disabled с подсказкой")
    func withoutSync() async throws {
        let page = try host.base.page("Отчёт")
        host.shares.isAvailable = false
        let response = try await share(["on", page.id.controlText])
        #expect(response.error?.code == .syncDisabled)
        #expect(response.error?.hint?.isEmpty == false)
    }

    @Test("Неизвестное действие — ошибка разбора")
    func unknownAction() throws {
        let spec = try #require(CommandCatalog.all.first { $0.name == "page.share" })
        #expect(throws: ControlError.self) { try ArgumentParser.parse(["publish", "Отчёт"], for: spec) { $0 } }
    }
}
