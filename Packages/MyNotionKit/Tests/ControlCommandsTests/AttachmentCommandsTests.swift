import ControlProtocol
import Databases
import Foundation
import os
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Вложения (этап 5, US4): файл с диска — блоком по типу (как перетащенный из Finder) или в ячейку «Файлы»; копия — по пути.
@MainActor @Suite struct AttachmentCommandsTests {
    let host: TestHost
    let executor: CommandExecutor

    /// Картинка 1×1 PNG.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    init() throws {
        host = try TestHost()
        executor = CommandExecutor(host: host, log: RecordingLog())
    }

    func run(_ command: String, _ args: [String: ControlJSON] = [:]) async -> ControlResponse {
        await executor.run(ControlRequest(command: command, args: args, agent: "codex", cwd: host.folder.url.path))
    }

    @discardableResult
    func ok(_ command: String, _ args: [String: ControlJSON] = [:], sourceLocation: SourceLocation = #_sourceLocation) async throws -> ControlJSON {
        let response = await run(command, args)
        try #require(response.ok, "\(command): \(response.error?.code.rawValue ?? "") \(response.error?.message ?? "")", sourceLocation: sourceLocation)
        return try #require(response.data, sourceLocation: sourceLocation)
    }

    /// Файл в папке теста; имя — относительный путь для `--file`.
    @discardableResult
    func file(_ name: String, _ data: Data) throws -> URL {
        let url = host.folder.url.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func blocks(_ pageId: UUID) throws -> [Block] {
        try host.store.pageContent(pageId)?.blocks.sorted { $0.sortKey < $1.sortKey } ?? []
    }

    @Test func addByFileType() async throws {
        let page = try host.page("Материалы", texts: ["вступление"])
        try file("отчёт.pdf", Data("%PDF-1.4 тест".utf8))
        try file("схема.png", Self.png)
        try file("ролик.mp4", Data(repeating: 7, count: 64))

        let pdf = try await ok("attachment.add", ["page": "Материалы", "file": "отчёт.pdf"])
        #expect(pdf["block"]?["kind"] == "file")
        #expect(pdf["attachment"]?["name"] == "отчёт.pdf")
        let image = try await ok("attachment.add", ["page": "Материалы", "file": "схема.png"])
        #expect(image["block"]?["kind"] == "image")
        let video = try await ok("attachment.add", ["page": "Материалы", "file": .string(host.folder.url.appendingPathComponent("ролик.mp4").path)])
        #expect(video["block"]?["kind"] == "video")
        let forced = try await ok("attachment.add", ["page": "Материалы", "file": "схема.png", "as": "file"])
        #expect(forced["block"]?["kind"] == "file")

        let stored = try blocks(page.id)
        #expect(stored.map(\.kind) == [.paragraph, .file, .image, .video, .file])
        #expect(stored[2].props.pixelSize == PixelSize(width: 1, height: 1))
        #expect(stored[3].props.videoSource == .file)
        #expect(stored[1].props.attachment?.name == "отчёт.pdf")
    }

    @Test func addAfterBlockAndReplaceEmptyParagraph() async throws {
        let page = try host.page("Пустая", texts: [""])
        try file("схема.png", Self.png)
        try await ok("attachment.add", ["page": "Пустая", "file": "схема.png"])
        #expect(try blocks(page.id).map(\.kind) == [.image])

        let notes = try host.page("Заметки", texts: ["первый", "второй"])
        let first = try #require(try blocks(notes.id).first)
        try await ok("attachment.add", ["page": "Заметки", "file": "схема.png", "after": .string(first.id.controlText)])
        #expect(try blocks(notes.id).map(\.kind) == [.paragraph, .image, .paragraph])
    }

    @Test func missingFile() async throws {
        try host.page("Материалы")
        let response = await run("attachment.add", ["page": "Материалы", "file": "нет-такого.pdf"])
        #expect(response.error?.code == .fileNotFound)
    }

    @Test func addToFilesCell() async throws {
        let operations = DatabaseOperations(store: host.store)
        let database = try operations.createDatabase(in: nil, isInline: false, title: "Задачи")
        let rowId = try operations.addRow(to: database.databaseId, in: database.viewId, title: "Отчёт")
        let property = try operations.addProperty(to: database.databaseId, name: "Файлы", kind: .files)
        try file("отчёт.pdf", Data("%PDF-1.4".utf8))

        let data = try await ok("attachment.add", ["page": "Задачи", "row": "Отчёт", "property": "Файлы", "file": "отчёт.pdf"])
        #expect(data["attachment"]?["name"] == "отчёт.pdf")
        #expect(data["row"]?["id"]?.string == rowId.controlText)
        let cell = try host.store.write { try $0.cell(rowId: rowId, propertyId: property.id) }
        #expect(FilesValue.items(cell?.value).map(\.name) == ["отчёт.pdf"])

        let wrong = await run("attachment.add", ["page": "Задачи", "row": "Отчёт", "property": "Название", "file": "отчёт.pdf"])
        #expect(wrong.error?.code == .invalidValue)
    }

    @Test func listAndGetCopy() async throws {
        try host.page("Материалы")
        let source = try file("схема.png", Self.png)
        let added = try await ok("attachment.add", ["page": "Материалы", "file": "схема.png"])
        let attachmentId = try #require(added["attachment"]?["id"]?.string)

        let list = try await ok("attachment.list", ["page": "Материалы"])
        #expect(list["items"]?.array?.count == 1)
        #expect(list["items"]?[0]?["id"]?.string == attachmentId)
        #expect(list["items"]?[0]?["blockId"]?.string == added["block"]?["id"]?.string)
        #expect(list["items"]?[0]?["kind"] == "image")

        let folder = host.folder.url.appendingPathComponent("выгрузка", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = try await ok("attachment.get", ["attachment": .string(attachmentId), "to": "выгрузка"])
        let path = try #require(saved["path"]?.string)
        #expect(path == folder.appendingPathComponent("схема.png").path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == (try Data(contentsOf: source)))

        let renamed = host.folder.url.appendingPathComponent("копия.png")
        try await ok("attachment.get", ["attachment": .string(String(attachmentId.prefix(8))), "to": .string(renamed.path)])
        #expect(try Data(contentsOf: renamed) == Self.png)

        let missing = await run("attachment.get", ["attachment": .string(UUID().uuidString), "to": "выгрузка"])
        #expect(missing.error?.code == .attachmentNotFound)
    }

    @Test func getDoesNotOverwriteStoredCopy() async throws {
        try host.page("Материалы")
        try file("схема.png", Self.png)
        let added = try await ok("attachment.add", ["page": "Материалы", "file": "схема.png"])
        let attachmentId = try #require(added["attachment"]?["id"]?.string.flatMap(UUID.init(uuidString:)))
        let stored = try #require(host.attachments.fileURL(for: attachmentId))

        // Сама копия и её папка: «сохранить поверх себя» стёрло бы файл вложения.
        for target in [stored.path, stored.deletingLastPathComponent().path] {
            let response = await run("attachment.get", ["attachment": .string(attachmentId.uuidString), "to": .string(target)])
            #expect(response.error?.code == .invalidValue, "\(target)")
        }
        #expect(try Data(contentsOf: stored) == Self.png)
    }

    @Test func getReplacesExistingFileWhole() async throws {
        try host.page("Материалы")
        try file("схема.png", Self.png)
        let added = try await ok("attachment.add", ["page": "Материалы", "file": "схема.png"])
        let attachmentId = try #require(added["attachment"]?["id"]?.string)
        let target = try file("старая.png", Data("прежнее содержимое".utf8))
        try await ok("attachment.get", ["attachment": .string(attachmentId), "to": .string(target.path)])
        #expect(try Data(contentsOf: target) == Self.png)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: host.folder.url.path).filter { $0.hasPrefix(".") && $0.contains("старая") }
        #expect(leftovers.isEmpty, "временный файл не остаётся")
    }

    @Test func importDoesNotHoldMainThread() async throws {
        try host.page("Материалы")
        // Файл — труба: импорт читает её, пока тест не допишет, а дописывает тест, только дождавшись главного потока.
        // Займи импорт главный поток, запись пришла бы лишь через минуту ожидания — уже не «пока импорт читает».
        let pipe = host.folder.url.appendingPathComponent("поток.bin")
        try #require(mkfifo(pipe.path, 0o600) == 0)
        let importOpened = OSAllocatedUnfairLock(initialState: false)
        let mainReached = DispatchSemaphore(value: 0)
        let released = OSAllocatedUnfairLock(initialState: false)
        let finished = OSAllocatedUnfairLock(initialState: false)
        Thread.detachNewThread {
            guard let writer = FileHandle(forWritingAtPath: pipe.path) else { return } // открывается, когда импорт открыл трубу
            importOpened.withLock { $0 = true }
            _ = mainReached.wait(timeout: .now() + 60)
            released.withLock { $0 = true }
            try? writer.write(contentsOf: Data(repeating: 7, count: 1_048_576))
            try? writer.close()
        }
        let add = Task {
            let response = await run("attachment.add", ["page": "Материалы", "file": "поток.bin"])
            finished.withLock { $0 = true }
            return response
        }
        while !importOpened.withLock({ $0 }), !finished.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let freeWhileImporting = !released.withLock { $0 }
        mainReached.signal()
        let response = await add.value
        try #require(response.ok, "\(response.error?.message ?? "")")
        #expect(freeWhileImporting, "главный поток ждал, пока импорт дочитает файл")
    }

    @Test func failedBatchLeavesNoAttachment() async throws {
        let page = try host.page("Материалы", texts: ["вступление"])
        try file("схема.png", Self.png)
        let response = await executor.run(ControlRequest(command: "batch", args: ["steps": [
            ["command": "attachment.add", "args": ["page": "Материалы", "file": "схема.png"]],
            ["command": "page.rename", "args": ["page": "Нет такой страницы", "title": "Б"]],
        ]], cwd: host.folder.url.path))
        #expect(response.error?.code == .batchFailed)
        #expect(try blocks(page.id).map(\.kind) == [.paragraph])
        #expect(try host.attachments.allRecords().isEmpty, "копия от отменённого шага не остаётся")
        let copies = (try? FileManager.default.contentsOfDirectory(atPath: host.attachments.folder.path)) ?? []
        #expect(copies.isEmpty)
    }
}
