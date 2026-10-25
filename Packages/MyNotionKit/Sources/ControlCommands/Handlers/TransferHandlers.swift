import Attachments
import ControlProtocol
import Foundation
import MarkdownExport
import NotesCore
import NotionImport

/// Импорт, выгрузка, синхронизация (этап 7, US6). Импорт и выгрузка идут теми же `NotionImporter` и `MarkdownExporter`,
/// что меню, в фоне: главный поток свободен, чтение не ждёт. Разрыв связи клиентом команду не прерывает (research R2).
public enum TransferHandlers {
    public static let all: [String: CommandHandler] = [
        "import.notion": importNotion,
        "export.page": { session in
            let page = try session.page()
            let (pageId, includingSubpages) = (page.id, !session.flag("noChildren"))
            return try await export(session, what: "«\(page.title)»") { exporter, folder, progress in
                try exporter.exportPage(pageId, includingSubpages: includingSubpages, into: folder, progress: progress)
            }
        },
        "export.all": { session in
            try await export(session, what: "все записи") { exporter, folder, progress in
                try exporter.export(into: folder, progress: progress)
            }
        },
        "db.export": { session in
            let database = try session.database().page
            return try await export(session, what: "базу «\(database.title)»") { exporter, folder, progress in
                try exporter.exportDatabase(database.id, into: folder, progress: progress)
            }
        },
        "sync.status": { session in
            let state = session.host.transferControl?.syncState ?? SyncState(status: .off)
            return CommandResult(SyncJSON.encode(state), text: SyncJSON.text(state))
        },
        "sync.now": { session in
            guard let control = session.host.transferControl, control.syncState.isEnabled else {
                throw ControlError(.syncDisabled, "Синхронизация на этом Mac выключена",
                                   hint: "Включить её можно только в окне: Настройки MyNotion → Синхронизация. Состояние: mynotion sync status")
            }
            let state = try await control.syncNow()
            return CommandResult(SyncJSON.encode(state), text: SyncJSON.text(state))
        },
    ]

    // MARK: Импорт

    static let importNotion: CommandHandler = { session in
        let source = try session.transferURL("source")
        let parent = try session.optionalPage("parent")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ControlError(.fileNotFound, "Нет файла «\(source.path)»", hint: "Архив .zip из Notion («Export → Markdown & CSV») или его папка",
                               details: ["argument": "source", "path": .string(source.path)])
        }
        let control = session.host.transferControl
        if control?.isImporting == true {
            throw ControlError(.windowBusy, "В окне MyNotion уже идёт импорт из Notion",
                               hint: "Дождаться конца: mynotion app status (поле importing)", details: ["reason": "importing"])
        }
        // Как меню: в импорт и рядом с ним — то, что уже на экране.
        try session.saveOpenPages(before: "импорт не начат")

        let store = session.host.store
        let attachments = ImportedFiles(store: session.host.attachments)
        let (steps, stepsOut) = AsyncStream.makeStream(of: NotionImportProgress.self, bufferingPolicy: .bufferingNewest(64))
        let job = Task.detached(priority: .userInitiated) { () -> Result<(NotionImportReport, NotionImportRun?), any Error> in
            defer { stepsOut.finish() }
            return Result {
                let prepared = try NotionExportUnpacker().prepare(source)
                defer { prepared.discard() }
                let importer = NotionImporter(store: store, attachments: attachments)
                // Меню спрашивает о повторе той же выгрузки; команда импортирует и сообщает о прошлом импорте в ответе.
                let previous = try importer.previousImport(withFingerprint: prepared.fingerprint)
                return (try importer.importExport(prepared) { stepsOut.yield($0) }, previous)
            }
        }
        control?.commandImportDidStart(stop: { job.cancel() })
        var pace = ProgressPace()
        for await step in steps {
            control?.commandImport(progress: step)
            guard pace.isDue(step) else { continue }
            session.report(ControlProgress(done: step.done, total: step.total, stage: step.phase == .reading ? "reading" : "writing"))
        }
        let outcome = await job.value
        control?.commandImportDidFinish(outcome.map(\.0))
        let (report, previous) = try outcome.mapError(importError).get()

        session.host.refreshAfterDirectWrite(pages: [report.rootPageId])
        if let parent {
            // Импорт уже записан: не перенёсся (страницу удалили, пока шёл импорт) — ветка остаётся, где её создал импорт; ответ успешный.
            do {
                try session.pageTree.move(report.rootPageId, toParent: parent.id, at: Int.max)
            } catch {
                session.warn(.notMoved, "Импорт прошёл, но в «\(parent.title)» не перенесён: \(ControlError.wrapping(error).message)")
            }
        }
        let outline = try PageOutline(store: store)
        var data: [String: ControlJSON] = ["report": ImportReportJSON.encode(report), "previousImport": .null]
        if let root = outline.page(report.rootPageId) { data["page"] = outline.json(root) }
        if let previous {
            data["previousImport"] = ["startedAt": .string(previous.startedAt.controlText),
                                      "rootPageId": previous.rootPageId.map { .string($0.controlText) } ?? .null]
        }
        let databases = report.databases.isEmpty ? "" : ", баз \(report.databases.count)"
        return CommandResult(.object(data), text: "✓ Импорт «\(report.rootTitle)»: страниц \(report.pageCount), блоков \(report.blockCount)\(databases)")
    }

    private static func importError(_ error: any Error) -> ControlError {
        switch error {
        case let error as ControlError:
            return error
        case is CancellationError:
            return ControlError(.writeFailed, "Импорт остановлен в окне: перенесённые страницы убраны, прежние записи не тронуты",
                                hint: "Запустить снова: mynotion import notion <архив>")
        case NotionImportError.sourceMissing(let path):
            return ControlError(.fileNotFound, "Нет файла «\(path)»", hint: "Архив .zip из Notion или его папка",
                                details: ["argument": "source", "path": .string(path)])
        case NotionImportError.cannotWrite(let reason):
            return ControlError(.writeFailed, NotionImportError.cannotWrite(reason).localizedDescription, hint: "Проверить место на диске и повторить")
        case let error as NotionImportError:
            return ControlError(.invalidValue, error.localizedDescription,
                                hint: "В Notion: «Export», формат «Markdown & CSV»; команде — архив .zip или его распакованная папка",
                                details: ["argument": "source"])
        default:
            return ControlError.wrapping(error)
        }
    }

    // MARK: Выгрузка

    /// Выгрузка в новую папку внутри `--to`; ход — строками `progress` по страницам.
    @MainActor private static func export(_ session: CommandSession, what: String,
                               _ body: @escaping @Sendable (MarkdownExporter, URL, @escaping @Sendable (MarkdownExportProgress) -> Void) throws
                                   -> MarkdownExportResult) async throws -> CommandResult {
        let folder = try session.transferURL("to")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ControlError(.fileNotFound, "Нет папки «\(folder.path)»", hint: "Создать её: mkdir -p \(folder.path)",
                               details: ["argument": "to", "path": .string(folder.path)])
        }
        // Как меню: в выгрузку попадает то, что на экране.
        try session.saveOpenPages(before: "выгрузка не начата")
        let attachments = session.host.attachments
        let exporter = MarkdownExporter(store: session.host.store, attachmentFile: { attachments.fileURL(for: $0) })
        let (steps, stepsOut) = AsyncStream.makeStream(of: MarkdownExportProgress.self, bufferingPolicy: .bufferingNewest(64))
        let job = Task.detached(priority: .userInitiated) { () -> Result<MarkdownExportResult, any Error> in
            defer { stepsOut.finish() }
            return Result { try body(exporter, folder) { stepsOut.yield($0) } }
        }
        var pace = ProgressPace()
        for await step in steps {
            guard pace.isDue(done: step.pagesDone, total: step.pagesTotal) else { continue }
            session.report(ControlProgress(done: step.pagesDone, total: step.pagesTotal, stage: "writing"))
        }
        let result = try await job.value.mapError(exportError).get()
        var data: [String: ControlJSON] = ["folder": .string(result.folder.path), "pageCount": .number(Double(result.pageCount)),
                                           "blockCount": .number(Double(result.blockCount)),
                                           "missingFiles": .number(Double(result.missingFileCount))]
        if result.missingFileCount > 0 { data["notice"] = .string(MarkdownExportResult.missingFilesMessage(count: result.missingFileCount)) }
        return CommandResult(.object(data), text: "✓ Выгружено \(what): страниц \(result.pageCount) → \(result.folder.path)")
    }

    private static func exportError(_ error: any Error) -> ControlError {
        switch error {
        case MarkdownExportError.destinationMissing(let path):
            return ControlError(.fileNotFound, "Нет папки «\(path)»", hint: "Создать её: mkdir -p \(path)",
                                details: ["argument": "to", "path": .string(path)])
        case let error as MarkdownExportError:
            return ControlError(.writeFailed, error.localizedDescription, hint: "Проверить папку и место на диске, повторить")
        default:
            return ControlError.wrapping(error)
        }
    }
}

/// Вложения импорта — в хранилище файлов приложения, как у импорта из меню.
private struct ImportedFiles: NotionAttachmentImporting {
    let store: AttachmentStore

    func importFile(at url: URL) throws -> AttachmentRef {
        try store.importFile(at: url)
    }
}

/// Строки хода — не на каждый шаг: первая, смена этапа, последняя и не чаще четырёх в секунду.
private struct ProgressPace {
    private var last: (stage: Int, at: ContinuousClock.Instant)?

    mutating func isDue(_ step: NotionImportProgress) -> Bool {
        isDue(done: step.done, total: step.total, stage: step.phase == .reading ? 0 : 1)
    }

    mutating func isDue(done: Int, total: Int, stage: Int = 0) -> Bool {
        let now = ContinuousClock.now
        let due = last.map { $0.stage != stage || done == total || now - $0.at >= .milliseconds(250) } ?? true
        if due { last = (stage, now) }
        return due
    }
}

extension CommandSession {
    /// Путь аргумента `key`: `~` — домашняя папка, относительный — от папки, где запущена команда.
    fileprivate func transferURL(_ key: String) throws(ControlError) -> URL {
        guard let text = string(key), !text.isEmpty else { throw CommandCatalog.missing(named: key, in: spec) }
        let expanded = (text as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        let base = request.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return base.appendingPathComponent(expanded).standardizedFileURL
    }

    /// Записать правки открытых страниц на диск; не записалось — команда не начинается.
    fileprivate func saveOpenPages(before outcome: String) throws(ControlError) {
        guard host.openDocuments.saveAll() else {
            throw ControlError(.writeFailed, "Правки открытой страницы не записались на диск — \(outcome)", hint: "Повторить через несколько секунд")
        }
    }
}

/// Отчёт импорта в ответе `import notion`: тот же, что в окне итога импорта из меню.
enum ImportReportJSON {
    static func encode(_ report: NotionImportReport) -> ControlJSON {
        [
            "rootPageId": .string(report.rootPageId.controlText), "rootTitle": .string(report.rootTitle),
            "pageCount": .number(Double(report.pageCount)), "blockCount": .number(Double(report.blockCount)),
            "databases": .array(report.databases.map { database in
                [
                    "title": .string(database.title), "rowCount": .number(Double(database.rowCount)),
                    "templateCount": .number(Double(database.templateCount)),
                    "properties": .array(database.properties.map(ControlJSON.string)), "notes": .array(database.notes.map(ControlJSON.string)),
                ]
            }),
            "simplified": .array(report.simplified.map { ["page": .string($0.pageTitle), "items": .array($0.items.map(ControlJSON.string))] }),
            "notices": .array(report.notices.map(ControlJSON.string)),
        ]
    }
}

/// Состояние синхронизации в ответе `sync status` и `sync now`.
enum SyncJSON {
    static func encode(_ state: SyncState) -> ControlJSON {
        [
            "enabled": .bool(state.isEnabled), "status": .string(state.status.rawValue), "detail": state.detail.map(ControlJSON.string) ?? .null,
            "lastSyncedAt": state.lastSyncedAt.map { .string($0.controlText) } ?? .null,
            "deviceName": state.deviceName.map(ControlJSON.string) ?? .null,
        ]
    }

    static func text(_ state: SyncState) -> String {
        switch state.status {
        case .off: "– Синхронизация выключена"
        case .ready: "✓ " + (state.detail ?? "Синхронизировано")
        case .sending: "… " + (state.detail ?? "Правки уходят на другие Mac")
        case .error: "✗ " + (state.detail ?? "Синхронизация не прошла")
        }
    }
}
