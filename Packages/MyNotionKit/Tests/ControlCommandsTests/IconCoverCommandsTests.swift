import ControlProtocol
import Foundation
import PageCover
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Иконка и обложка страницы командами (US2): та же правка поля, что в окне, один шаг отмены, окно узнаёт о смене.
@MainActor @Suite struct IconCoverCommandsTests {
    let host: TestHost
    let executor: CommandExecutor
    let page: Page

    init() throws {
        host = try TestHost()
        executor = CommandExecutor(host: host, log: RecordingLog())
        page = try host.page("Проект", texts: ["текст"])
    }

    @discardableResult
    func run(_ command: String, _ args: [String: ControlJSON] = [:]) async -> ControlResponse {
        var args = args
        if args["page"] == nil, command != "batch", command != "page.cover" || args["list"] == nil { args["page"] = .string(page.id.controlText) }
        return await executor.run(ControlRequest(command: command, args: args))
    }

    func current() throws -> Page {
        try #require(try host.stored(page.id))
    }

    func expectError(_ response: ControlResponse, _ code: ControlErrorCode) {
        #expect(!response.ok)
        #expect(response.error?.code == code, "Получили \(response.error?.code.rawValue ?? "успех"): \(response.error?.message ?? "")")
    }

    /// Картинка 1 × 1 во временной папке.
    func makeImage(named name: String = "обложка.png") throws -> URL {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        let url = host.folder.url.appendingPathComponent(name)
        try png.write(to: url)
        return url
    }

    // MARK: Иконка

    @Test func iconSetAndRemove() async throws {
        let response = await run("page.icon", ["emoji": "🚀"])
        #expect(response.ok)
        #expect(try current().icon == "🚀")
        #expect(response.data?["page"]?["icon"] == "🚀")
        #expect(response.data?["page"]?["id"] == .string(page.id.controlText))

        let removed = await run("page.icon", ["remove": true])
        #expect(removed.ok)
        #expect(try current().icon == nil)
        #expect(removed.data?["page"]?["icon"] == .null)
    }

    @Test func iconAcceptsComposedEmoji() async throws {
        for emoji in ["👨‍👩‍👧", "🇷🇺", "1️⃣", "✅"] {
            let response = await run("page.icon", ["emoji": .string(emoji)])
            #expect(response.ok, "\(emoji): \(response.error?.message ?? "")")
            #expect(try current().icon == emoji)
        }
    }

    @Test func iconRejectsNonEmoji() async throws {
        for text in ["ракета", "🚀🚀", "", "a"] {
            expectError(await run("page.icon", ["emoji": .string(text)]), .invalidValue)
        }
        #expect(try current().icon == nil)
    }

    @Test func iconNeedsEmojiOrRemove() async throws {
        expectError(await run("page.icon"), .missingArgument)
        expectError(await run("page.icon", ["emoji": "🚀", "remove": true]), .invalidArgument)
    }

    // Отмена видна тестам только в отладочной сборке: `CommandExecutor.lastUndoManager` есть только там.
    #if DEBUG
    @Test func iconIsOneUndoStepAndTellsTheWindow() async throws {
        await run("page.icon", ["emoji": "🚀"])
        #expect(host.iconChanges == [page.id])
        #expect(host.treeChanges.isEmpty, "страница не перечитывается: иначе курсор Юрия сбрасывается")
        executor.lastUndoManager?.undo()
        #expect(try current().icon == nil)
        executor.lastUndoManager?.redo()
        #expect(try current().icon == "🚀")
    }
    #endif

    @Test func iconIgnoresMissingPage() async throws {
        expectError(await run("page.icon", ["page": "Нет такой", "emoji": "🚀"]), .pageNotFound)
    }

    // MARK: Обложка

    @Test func listShowsWholeGallery() async throws {
        let response = await run("page.cover", ["list": true])
        #expect(response.ok)
        let items = response.data?["gallery"]?.array ?? []
        #expect(items.compactMap { $0["id"]?.string } == CoverGallery.ids)
        #expect(items.allSatisfy { $0["title"]?.string?.isEmpty == false })
        #expect(try current().cover == nil, "Просмотр галереи страницу не трогает")
    }

    @Test func galleryCoverByIdAndByTitle() async throws {
        let response = await run("page.cover", ["gallery": "gradients_3"])
        #expect(response.ok)
        #expect(try current().cover == PageCover(source: .gallery("gradients_3")))
        #expect(response.data?["page"]?["cover"]?["gallery"] == "gradients_3")
        #expect(response.data?["page"]?["cover"]?["offset"] == 0.5)

        await run("page.cover", ["gallery": "красный"])
        #expect(try current().cover?.source == .gallery("solid_red"))
    }

    @Test func galleryCoverWithOffset() async throws {
        await run("page.cover", ["gallery": "solid_blue", "offset": 0.2])
        #expect(try current().cover == PageCover(source: .gallery("solid_blue"), offset: 0.2))
    }

    @Test func unknownGalleryNameListsTheGallery() async throws {
        let response = await run("page.cover", ["gallery": "радуга"])
        expectError(response, .invalidValue)
        #expect(response.error?.details?["allowed"]?.array?.compactMap(\.string) == CoverGallery.ids)
        #expect(response.error?.hint?.contains("--list") == true)
        #expect(try current().cover == nil)
    }

    @Test func offsetAloneMovesExistingCover() async throws {
        await run("page.cover", ["gallery": "solid_blue"])
        let response = await run("page.cover", ["offset": 0.9])
        #expect(response.ok)
        #expect(try current().cover == PageCover(source: .gallery("solid_blue"), offset: 0.9))
        expectError(await run("page.cover", ["offset": 1.5]), .invalidValue)
        expectError(await run("page.cover", ["offset": -0.1]), .invalidValue)
        #expect(try current().cover?.offset == 0.9)
    }

    @Test func offsetWithoutCoverFails() async throws {
        expectError(await run("page.cover", ["offset": 0.3]), .invalidArgument)
    }

    @Test func fileCoverStoresAttachment() async throws {
        let image = try makeImage()
        let response = await run("page.cover", ["file": .string(image.path), "offset": 0.4])
        #expect(response.ok, "\(response.error?.message ?? "")")
        let cover = try #require(try current().cover)
        let ref = try #require(cover.attachment)
        #expect(cover.offset == 0.4)
        #expect(ref.name == "обложка.png")
        #expect(response.data?["page"]?["cover"]?["attachmentId"] == .string(ref.id.controlText))
        #expect(host.attachments.fileURL(for: ref.id) != nil)
    }

    @Test func fileCoverRejectsMissingAndNonImageFiles() async throws {
        let missing = await run("page.cover", ["file": .string(host.folder.url.appendingPathComponent("нет.png").path)])
        expectError(missing, .fileNotFound)

        let text = host.folder.url.appendingPathComponent("заметка.txt")
        try Data("не картинка".utf8).write(to: text)
        let notImage = await run("page.cover", ["file": .string(text.path)])
        expectError(notImage, .invalidValue)
        #expect(try current().cover == nil)
    }

    @Test func removeCover() async throws {
        await run("page.cover", ["gallery": "solid_red"])
        let response = await run("page.cover", ["remove": true])
        #expect(response.ok)
        #expect(try current().cover == nil)
        #expect(response.data?["page"]?["cover"] == .null)
        let again = await run("page.cover", ["remove": true])
        #expect(again.ok, "Убрать обложку, которой нет, — не ошибка")
    }

    @Test func coverNeedsAnAction() async throws {
        expectError(await run("page.cover"), .missingArgument)
        expectError(await run("page.cover", ["gallery": "solid_red", "remove": true]), .invalidArgument)
        expectError(await run("page.cover", ["gallery": "solid_red", "file": "/tmp/a.png"]), .invalidArgument)
    }

    // Отмена видна тестам только в отладочной сборке: `CommandExecutor.lastUndoManager` есть только там.
    #if DEBUG
    @Test func coverIsOneUndoStepAndTellsTheWindow() async throws {
        await run("page.cover", ["gallery": "solid_red", "offset": 0.1])
        #expect(host.appearanceChanges == [page.id])
        #expect(host.treeChanges.isEmpty, "страница не перечитывается: иначе курсор Юрия сбрасывается")
        executor.lastUndoManager?.undo()
        #expect(try current().cover == nil)
        executor.lastUndoManager?.redo()
        #expect(try current().cover == PageCover(source: .gallery("solid_red"), offset: 0.1))
    }
    #endif

    @Test func batchRollsBackIconAndCover() async throws {
        let response = await run("batch", ["steps": [
            ["command": "page.icon", "args": ["page": .string(page.id.controlText), "emoji": "🚀"]],
            ["command": "page.cover", "args": ["page": .string(page.id.controlText), "gallery": "solid_red"]],
            ["command": "page.cover", "args": ["page": .string(page.id.controlText), "gallery": "радуга"]],
        ]])
        #expect(response.error?.code == .batchFailed, "\(response.error?.message ?? "")")
        #expect(try current().icon == nil)
        #expect(try current().cover == nil)
    }

    @Test func writingLeavesAgentVersion() async throws {
        await run("page.icon", ["emoji": "🚀"])
        #expect(try host.versions.versions(ofPage: page.id).contains { $0.summary.agent != nil })
    }
}
