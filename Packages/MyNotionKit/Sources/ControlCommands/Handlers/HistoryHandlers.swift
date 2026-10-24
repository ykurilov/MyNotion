import ControlProtocol
import Foundation
import NotesCore
import PageMarkdown
import PageVersions

/// История версий (этап 5, US4): как окно истории 003 — список с первой строкой «текущий вид», просмотр версии,
/// восстановление с версиями «до» и «после».
enum HistoryHandlers {
    static let all: [String: CommandHandler] = [
        "history.list": list, "history.show": show, "history.restore": restore,
    ]

    /// Как «История версий» в окне: неснятые правки сначала становятся версией.
    static let list: CommandHandler = { session in
        let page = try session.page()
        session.host.openDocuments.saveAll()
        try await session.host.versionRecorder.recordPending(page.id)
        let versions = try session.host.versions.versions(ofPage: page.id)
        return CommandResult(try session.paged(versions.map(json)), text: "\(versions.count) версий «\(page.title)»")
    }

    static let show: CommandHandler = { session in
        let page = try session.page()
        let version = try session.version(ofPage: page.id)
        guard let snapshot = try session.host.versions.snapshot(version.id) else { throw versionGone(version.id) }
        var data = session.encodedContent(snapshot.blocks(onPage: page.id), outline: try PageOutline(store: session.host.store))
        data["version"] = json(version)
        data["title"] = .string(snapshot.title)
        data["icon"] = snapshot.icon.map(ControlJSON.string) ?? .null
        return CommandResult(.object(data), text: "«\(snapshot.title)», \(version.createdAt.controlText)")
    }

    /// «Восстановить эту версию»: одна правка страницы; вид до неё помечен «до восстановления».
    static let restore: CommandHandler = { session in
        let page = try session.page()
        try PageOutline(store: session.host.store).requireEditable(page)
        let version = try session.version(ofPage: page.id)
        session.host.openDocuments.saveAll()
        let restorer = VersionRestorer(recorder: session.host.versionRecorder, versions: session.host.versions, operations: session.pageTree)
        do {
            try await restorer.restore(versionId: version.id, ofPage: page.id)
        } catch VersionRestoreError.versionGone {
            throw versionGone(version.id)
        }
        var result = try session.pageResult(page.id)
        var data = result.data.object ?? [:]
        data["restoredVersion"] = json(version)
        result.data = .object(data)
        result.text = "✓ «\(page.title)» — версия \(version.createdAt.controlText)"
        return result
    }

    static func json(_ version: PageVersionInfo) -> ControlJSON {
        [
            "id": .string(version.id.controlText), "createdAt": .string(version.createdAt.controlText),
            "device": .string(version.deviceName), "summary": .string(version.summary.lines.joined(separator: ", ")),
            "agent": version.summary.agent.map(ControlJSON.string) ?? .null, "byteCount": .number(Double(version.byteCount)),
        ]
    }

    static func versionGone(_ id: UUID) -> ControlError {
        ControlError(.versionNotFound, "Версии \(id.controlText) уже нет: её убрало прореживание истории", hint: "Версии: mynotion history list <стр>",
                     details: ["version": .string(id.controlText)])
    }
}

extension CommandSession {
    /// Версия страницы по аргументу `version`: id или его начало (от 8 знаков).
    func version(ofPage pageId: UUID) throws -> PageVersionInfo {
        guard let text = string("version")?.trimmingCharacters(in: .whitespaces).lowercased() else {
            throw CommandCatalog.missing(named: "version", in: spec)
        }
        let versions = try host.versions.versions(ofPage: pageId)
        let matches = UUID(uuidString: text).map { id in versions.filter { $0.id == id } }
            ?? (PageLocator.isIdPrefix(text) ? versions.filter { $0.id.controlText.hasPrefix(text) } : [])
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw ControlError(.invalidValue, "Версий с началом id «\(text)» несколько (\(matches.count)): укажите id целиком",
                               hint: "Версии: mynotion history list \(pageId.controlText)",
                               details: ["candidates": .array(matches.prefix(PageLocator.candidateLimit).map { .string($0.id.controlText) })])
        }
        throw ControlError(.versionNotFound, "У страницы нет версии «\(text)»", hint: "Версии: mynotion history list \(pageId.controlText)",
                           details: ["version": .string(text)])
    }

    /// Блоки Markdown-ом (тем же преобразованием, что `page read`) или JSON блоков — по `--format`.
    func encodedContent(_ blocks: [Block], outline: PageOutline) -> [String: ControlJSON] {
        let titles = outline.titles
        if string("format") == "json" {
            let byContainer = Dictionary(grouping: blocks, by: \.containerId).mapValues { $0.sorted { $0.sortKey < $1.sortKey } }
            func encode(_ block: Block) -> ControlJSON {
                BlockJSON.encode(block, titles: { titles[$0] }, children: byContainer[block.id]?.map(encode))
            }
            return ["blocks": .array((byContainer[nil] ?? []).map(encode))]
        }
        let attachments = host.attachments
        let reader = PageMarkdownReader(pageTitle: { titles[$0] }, attachmentPath: { ref in
            (attachments.fileURL(for: ref.id)
                ?? attachments.folder.appendingPathComponent(ref.id.uuidString.lowercased()).appendingPathComponent(ref.name)).path
        })
        return ["markdown": .string(reader.markdown(for: blocks))]
    }
}
