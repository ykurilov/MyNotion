import Attachments
import Foundation
import NotesCore
import NotionImport

/// Markdown агента → блоки страницы (005, research R7): разбор Notion в режиме `.plainMarkdown` и тот же перевод
/// `ParsedBlockConverter`, что у импорта. Ссылка `mynotion://page/<id>` строкой — подстраница или встроенная база,
/// внутри строки — упоминание; файл по пути — вложение; чего в MyNotion нет — текстом и предупреждением со строкой.
public struct MarkdownBlocksBuilder {
    public struct Result {
        public var blocks: [Block]
        public var warnings: [PageMarkdownWarning]
    }

    private let attachments: AttachmentStore?
    /// Папка, от которой считаются относительные пути файлов (папка, где агент запустил команду).
    private let baseFolder: URL?
    /// Вложения, уже стоящие в блоках страницы: путь их копии возвращает тот же файл, без новой копии.
    private let knownAttachments: [UUID: AttachmentRef]
    /// Страница по id ссылки; `nil` — такой страницы нет.
    private let linkTarget: (UUID) -> ParsedBlockConverter.LinkTarget?

    public init(attachments: AttachmentStore?, baseFolder: URL?, knownAttachments: [AttachmentRef] = [],
                linkTarget: @escaping (UUID) -> ParsedBlockConverter.LinkTarget?) {
        self.attachments = attachments
        self.baseFolder = baseFolder
        self.knownAttachments = Dictionary(knownAttachments.map { ($0.id, $0) }) { first, _ in first }
        self.linkTarget = linkTarget
    }

    /// Блоки всех потоков с ключами порядка с начала страницы. Пустой Markdown — ни одного блока.
    public func blocks(fromMarkdown markdown: String, pageId: UUID) -> Result {
        let page = NotionMarkdownParser(options: .plainMarkdown).parse(markdown)
        var warnings = page.warnings.map { PageMarkdownWarning(line: $0.line, message: $0.message) }
        var parsed = page.blocks
        attach(&parsed, warnings: &warnings)
        let blocks = ParsedBlockConverter.blocks(from: parsed, pageId: pageId, linkTarget: { block in
            guard let url = block.standaloneURL, let id = PageMarkdown.pageId(from: url) else { return nil }
            return linkTarget(id)
        }, mentionTarget: { _ in nil })
        var unknownLinks = 0
        let folded = blocks.map { block in
            var block = block
            let known = block.text.runs.filter { run in
                guard case .link(let url) = run.style, let id = PageMarkdown.pageId(from: url) else { return true }
                return linkTarget(id) != nil
            }
            unknownLinks += block.text.runs.count - known.count
            // Ссылка на страницу, которой нет, — её название простым текстом.
            block.text = PageMarkdown.foldingPageLinks(in: InlineText(block.text.string, runs: known))
            return block
        }
        if unknownLinks > 0 {
            warnings.append(PageMarkdownWarning(line: nil, message: "ссылок на неизвестные страницы: \(unknownLinks) — оставлены названием"))
        }
        return Result(blocks: folded, warnings: warnings)
    }

    // MARK: Файлы

    /// Картинки и файлы по пути — вложениями; файла нет или он не копируется — абзац «[файл: имя]» и предупреждение.
    private func attach(_ blocks: inout [ParsedBlock], warnings: inout [PageMarkdownWarning]) {
        for position in blocks.indices {
            attach(&blocks[position].contained, warnings: &warnings)
            for (file, path) in blocks[position].decorationPaths {
                guard let ref = attachment(at: path) else { continue }
                switch file {
                case .poster: blocks[position].props.poster = ref
                case .image: blocks[position].props.image = ref
                case .icon: blocks[position].props.iconAttachment = ref
                }
            }
            blocks[position].decorationPaths = [:]
            guard let path = blocks[position].attachmentPath else { continue }
            blocks[position].attachmentPath = nil
            if let ref = attachment(at: path) {
                blocks[position].props.attachment = ref
                if blocks[position].kind == .image, blocks[position].props.pixelSize == nil,
                   let url = attachments?.fileURL(for: ref.id), let size = PixelSize(ofImageAt: url) {
                    blocks[position].props.pixelSize = size
                }
            } else {
                let name = (path as NSString).lastPathComponent
                blocks[position] = ParsedBlock(kind: .paragraph, text: InlineText("[файл: \(name)]"), indent: blocks[position].indent)
                warnings.append(PageMarkdownWarning(line: nil, message: "файл не найден или не копируется: \(path)"))
            }
        }
    }

    /// Путь копии во вложениях — то же вложение; другой файл — новая копия.
    private func attachment(at path: String) -> AttachmentRef? {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else if let baseFolder {
            url = baseFolder.appendingPathComponent(path)
        } else {
            return nil
        }
        let file = url.standardizedFileURL
        if let attachments {
            let folder = attachments.folder.standardizedFileURL.path + "/"
            if file.path.hasPrefix(folder), let key = file.path.dropFirst(folder.count).split(separator: "/").first,
               let id = UUID(uuidString: String(key)) {
                if let ref = knownAttachments[id] ?? (try? attachments.record(id))?.ref { return ref }
            }
        }
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try? attachments?.importFile(at: file)
    }
}
