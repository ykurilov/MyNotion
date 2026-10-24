import Attachments
import ControlProtocol
import Databases
import Foundation
import NotesCore
import UniformTypeIdentifiers

/// Вложения (этап 5, US4): файл с диска — блоком, как перетащенный из Finder (картинка, видео или файл по типу), или в
/// ячейку «Файлы» строки; список файлов страницы; копия вложения по пути.
enum AttachmentHandlers {
    static let all: [String: CommandHandler] = [
        "attachment.add": add, "attachment.list": list, "attachment.get": get,
    ]

    static let add: CommandHandler = { session in
        let source = try session.existingFile("file")
        if session.args["row"] != nil || session.args["property"] != nil { return try await addToCell(session, source) }
        let page = try session.page()
        let outline = try PageOutline(store: session.host.store)
        try outline.requireEditable(page)
        let stored = try session.optionalBlock("after", inPage: page.id)
        let ref = try await session.importAttachment(source)
        let draft = mediaBlock(for: ref, file: source, kind: session.string("as").flatMap(BlockKind.init(rawValue:)), pageId: page.id)
        var inserted = draft
        try await session.editContent(of: page.id, checkpoint: true) { document in
            let anchor = stored.map { document.block($0.id) ?? $0 } ?? document.blocks.filter { $0.containerId == nil }.max { $0.sortKey < $1.sortKey }
            guard let anchor else { return BlockChanges(upserts: [inserted]) }
            inserted.containerId = anchor.containerId
            inserted.indent = anchor.indent
            // Как вставка в окне: пустой абзац под курсором становится файлом.
            if anchor.kind == .paragraph, anchor.text.string.isEmpty, !document.blocks.contains(where: { $0.containerId == anchor.id }) {
                inserted.sortKey = anchor.sortKey
                return BlockChanges(upserts: [inserted], removals: [anchor.id])
            }
            let next = document.blocks.filter { $0.containerId == anchor.containerId && $0.sortKey > anchor.sortKey }.map(\.sortKey).min()
            inserted.sortKey = .between(anchor.sortKey, next)
            return BlockChanges(upserts: [inserted])
        }
        let titles = outline.titles
        return CommandResult(["block": BlockJSON.encode(inserted, titles: { titles[$0] }), "attachment": session.attachmentJSON(ref),
                              "page": outline.json(page)],
                             text: "✓ «\(ref.name)» на странице «\(page.title)»")
    }

    /// В ячейку «Файлы»: `<база> <строка> <свойство>`.
    @MainActor static func addToCell(_ session: CommandSession, _ source: URL) async throws -> CommandResult {
        let database = try session.database("page")
        let refs = session.databaseRefs
        guard let rowText = session.string("row") else { throw CommandCatalog.missing(named: "row", in: session.spec) }
        guard let propertyText = session.string("property") else { throw CommandCatalog.missing(named: "property", in: session.spec) }
        let row = try refs.row(rowText, inDatabase: database.page.id)
        let property = try refs.property(propertyText, in: database.catalog)
        guard property.kind == .files else {
            throw ControlError(.invalidValue, "«\(property.name)» — не свойство «Файлы»", hint: "Свойства: mynotion db schema \(database.page.id.controlText)",
                               details: ["property": .string(property.name), "kind": .string("\(property.kind)")])
        }
        let ref = try await session.importAttachment(source)
        try session.databases.addFiles([.file(ref)], rowId: row.id, propertyId: property.id)
        var result = try session.rowResult(row.id, of: database.page.id, "✓ «\(ref.name)» в «\(property.name)» у «\(row.displayTitle)»")
        var data = result.data.object ?? [:]
        data["attachment"] = session.attachmentJSON(ref)
        result.data = .object(data)
        return result
    }

    /// Обложка, затем файлы блоков в порядке чтения.
    static let list: CommandHandler = { session in
        let page = try session.page()
        let blocks = try session.host.openDocuments.document(for: page.id)?.blocks ?? session.host.store.pageContent(page.id)?.blocks ?? []
        var items: [ControlJSON] = []
        if case .file(let ref)? = page.cover?.source { items.append(session.attachmentJSON(ref, kind: "cover")) }
        for block in readingOrder(blocks) {
            for ref in block.props.attachmentRefs { items.append(session.attachmentJSON(ref, kind: block.kind.rawValue, blockId: block.id)) }
        }
        return CommandResult(try session.paged(items), text: "\(items.count) вложений «\(page.title)»")
    }

    /// Копия файла: в папку под своим именем или по пути файла. В папку копий приложения — нельзя: «сохранить поверх
    /// себя» стёрло бы файл вложения. Прежний файл по пути заменяется целиком, только когда копия уже готова.
    static let get: CommandHandler = { session in
        let ref = try session.attachment()
        guard let file = session.host.attachments.fileURL(for: ref.id) else {
            throw ControlError(.attachmentNotFound, "Файла «\(ref.name)» ещё нет на этом Mac: он скачивается", hint: "Повторите позже: mynotion sync status",
                               details: ["attachmentId": .string(ref.id.controlText)])
        }
        var destination = try session.diskURL("to")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            destination = destination.appendingPathComponent(ref.name)
        }
        guard FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path) else {
            throw ControlError(.fileNotFound, "Нет папки «\(destination.deletingLastPathComponent().path)»", hint: "Создайте её: mkdir -p <папка>",
                               details: ["argument": "to", "path": .string(destination.path)])
        }
        let folder = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        let copies = session.host.attachments.folder.resolvingSymlinksInPath()
        guard !(folder.path + "/").hasPrefix(copies.path + "/") else {
            throw ControlError(.invalidValue, "«\(destination.path)» — в папке копий MyNotion: так можно затереть само вложение",
                               hint: "Другой путь в --to, например ~/Desktop", details: ["argument": "to", "path": .string(destination.path)])
        }
        let staging = folder.appendingPathComponent(".\(destination.lastPathComponent).mynotion-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: file, to: staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw ControlError(.writeFailed, "Не записать «\(destination.path)»: \(error.localizedDescription)", hint: "Другой путь в --to")
        }
        return CommandResult(["path": .string(destination.path), "attachment": session.attachmentJSON(ref)], text: "✓ \(destination.path)")
    }

    /// Блок для файла, как `AttachmentInsertion.mediaDraft` окна: вид по типу файла или заданный.
    static func mediaBlock(for ref: AttachmentRef, file: URL, kind forced: BlockKind?, pageId: UUID) -> Block {
        let type = UTType(ref.contentType)
        let kind = forced ?? (type?.conforms(to: .image) == true ? .image : type?.conforms(to: .audiovisualContent) == true ? .video : .file)
        var props = BlockProps()
        props.attachment = ref
        if kind == .video { props.videoSource = .file }
        if kind == .image, let size = PixelSize(ofImageAt: file) { props.pixelSize = size }
        return Block(pageId: pageId, kind: kind, sortKey: .between(nil, nil), props: props)
    }

    /// Блоки как на странице: верхний уровень по порядку, вложенные — сразу за своим блоком.
    static func readingOrder(_ blocks: [Block]) -> [Block] {
        let byContainer = Dictionary(grouping: blocks, by: \.containerId).mapValues { $0.sorted { $0.sortKey < $1.sortKey } }
        var ordered: [Block] = []
        func append(_ containerId: UUID?) {
            for block in byContainer[containerId] ?? [] {
                ordered.append(block)
                append(block.id)
            }
        }
        append(nil)
        return ordered
    }
}

extension CommandSession {
    /// Копия файла в папке приложения; ссылка на неё появится в блоке или ячейке. Копирование и подсчёт суммы — не на
    /// главном потоке: окна не замирают на файле в 100 МБ. Откат команды стирает копию, если на неё никто не ссылается.
    func importAttachment(_ source: URL) async throws(ControlError) -> AttachmentRef {
        let attachments = host.attachments
        do {
            let ref = try await Task.detached(priority: .userInitiated) { try attachments.importFile(at: source) }.value
            context.importedAttachments.append(ref.id)
            return ref
        } catch AttachmentError.tooLarge(_) {
            throw ControlError(.invalidValue, "«\(source.lastPathComponent)» больше 100 МБ: MyNotion такие не хранит", hint: "Файл поменьше",
                               details: ["argument": "file", "path": .string(source.path)])
        } catch {
            throw ControlError(.fileNotFound, "Не прочитать «\(source.path)»: \(error.localizedDescription)", hint: "Проверьте путь и права",
                               details: ["argument": "file", "path": .string(source.path)])
        }
    }

    /// Вложение по аргументу `attachment`: id или его начало (от 8 знаков).
    func attachment() throws -> AttachmentRef {
        guard let text = string("attachment")?.trimmingCharacters(in: .whitespaces).lowercased() else {
            throw CommandCatalog.missing(named: "attachment", in: spec)
        }
        let notFound = ControlError(.attachmentNotFound, "Нет вложения «\(text)»", hint: "Вложения страницы: mynotion attachment list <стр>",
                                    details: ["attachmentId": .string(text)])
        if let id = UUID(uuidString: text) {
            guard let record = try host.attachments.record(id) else { throw notFound }
            return record.ref
        }
        guard PageLocator.isIdPrefix(text) else { throw notFound }
        let matches = try host.attachments.allRecords().filter { $0.id.controlText.hasPrefix(text) }
        if matches.count == 1 { return matches[0].ref }
        if matches.count > 1 {
            throw ControlError(.invalidValue, "Вложений с началом id «\(text)» несколько (\(matches.count)): укажите id целиком",
                               hint: "Вложения страницы: mynotion attachment list <стр>",
                               details: ["candidates": .array(matches.prefix(PageLocator.candidateLimit).map { .string($0.id.controlText) })])
        }
        throw notFound
    }

    /// Вложение в ответах: `path` — копия на этом Mac, `null` — файл ещё скачивается.
    func attachmentJSON(_ ref: AttachmentRef, kind: String? = nil, blockId: UUID? = nil) -> ControlJSON {
        var object: [String: ControlJSON] = [
            "id": .string(ref.id.controlText), "name": .string(ref.name), "byteCount": .number(Double(ref.byteCount)),
            "contentType": .string(ref.contentType), "path": host.attachments.fileURL(for: ref.id).map { .string($0.path) } ?? .null,
        ]
        if let kind { object["kind"] = .string(kind) }
        if kind != nil { object["blockId"] = blockId.map { .string($0.controlText) } ?? .null }
        return .object(object)
    }
}
