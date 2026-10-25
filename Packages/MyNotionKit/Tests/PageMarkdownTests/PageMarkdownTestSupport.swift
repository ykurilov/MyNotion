import Attachments
import Foundation
import NotesCore
import NotionImport
@testable import PageMarkdown

/// Временная база с вложениями: чтение и запись Markdown страницы так, как их делают команды.
final class PageMarkdownFixture {
    let folder: URL
    let store: NotesStore
    let attachments: AttachmentStore

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PageMarkdownTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")),
                           clock: HybridLogicalClock(deviceId: UUID()))
        attachments = AttachmentStore(store: store, folder: folder.appendingPathComponent("Attachments", isDirectory: true))
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)

    func blocks(of pageId: UUID) throws -> [Block] {
        try store.pageContent(pageId)?.blocks ?? []
    }

    func reader() throws -> PageMarkdownReader {
        let pages = Dictionary(uniqueKeysWithValues: try store.pageOutline().map { ($0.id, $0) })
        let attachments = attachments
        return PageMarkdownReader(pageTitle: { id in pages[id].map { ($0.title, $0.icon) } }, attachmentPath: { ref in
            (attachments.fileURL(for: ref.id) ?? attachments.folder.appendingPathComponent(ref.id.uuidString.lowercased())
                .appendingPathComponent(ref.name)).path
        })
    }

    func builder(known: [AttachmentRef] = [], baseFolder: URL? = nil) throws -> MarkdownBlocksBuilder {
        let outline = try store.treeOutline()
        let pages = Set(outline.pages.map(\.id))
        return MarkdownBlocksBuilder(attachments: attachments, baseFolder: baseFolder, knownAttachments: known) { id in
            guard pages.contains(id) else { return nil }
            return outline.databases[id] == true ? .database(id) : .page(id)
        }
    }

    /// Страница с Markdown, записанным как команда: блоки в базу.
    @discardableResult
    func page(title: String, id: UUID = .timeOrdered(), markdown: String? = nil) throws -> UUID {
        let lastRootKey = try store.pageOutline().filter { $0.parentId == nil }.map(\.sortKey).max()
        let blocks = try markdown.map { try builder().blocks(fromMarkdown: $0, pageId: id).blocks } ?? []
        try store.write { transaction in
            try transaction.insertPage(Page(id: id, title: title, sortKey: .between(lastRootKey, nil), createdAt: Date(), updatedAt: Date()))
            for block in blocks { try transaction.insertBlock(block) }
        }
        return id
    }

    /// Прочитать → записать → прочитать: оба Markdown.
    func roundTrip(_ pageId: UUID) throws -> (first: String, second: String) {
        let blocks = try blocks(of: pageId)
        let first = try reader().markdown(for: blocks)
        let refs = blocks.flatMap { [$0.props.attachment, $0.props.poster, $0.props.image, $0.props.iconAttachment].compactMap { $0 } }
        let rebuilt = try builder(known: refs).blocks(fromMarkdown: first, pageId: pageId).blocks
        return (first, try reader().markdown(for: rebuilt))
    }
}
