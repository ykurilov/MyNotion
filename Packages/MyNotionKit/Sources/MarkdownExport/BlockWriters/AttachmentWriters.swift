import Foundation
import LinkPreview
import NotesCore

/// Картинка, файл, видео, закладка в Markdown (contracts/markdown-and-notion.md, «Блоки» и «Файлы»): копии файлов —
/// в папке страницы, ещё не скачанный файл — строка «[файл не скачан: имя]».

/// `![подпись](Страница/имя.png)`; ширина не 100 % — `<img src alt data-width>`.
struct ImageWriter: MarkdownBlockKindWriter {
    var kinds: Set<BlockKind> { [.image] }

    func lines(for block: Block, children: [String], context: MarkdownWriteContext) -> [String]? {
        guard let ref = block.props.attachment else { return nil }
        guard let path = context.resolveAttachment(ref) else { return [AttachmentMarkup.notDownloaded(ref)] }
        let caption = block.text.string.replacingOccurrences(of: "\n", with: " ")
        if let width = block.props.width, width < 0.999 {
            return ["<img src=\"\(AttachmentMarkup.attribute(InlineMarkdown.encodedPath(path)))\" alt=\"\(AttachmentMarkup.attribute(caption))\" "
                + "data-width=\"\(AttachmentMarkup.number(width))\">"]
        }
        return ["![\(AttachmentMarkup.bracketed(caption))](\(InlineMarkdown.encodedPath(path)))"]
    }
}

/// `[имя.pdf](Страница/имя.pdf)` отдельной строкой.
struct FileWriter: MarkdownBlockKindWriter {
    var kinds: Set<BlockKind> { [.file] }

    func lines(for block: Block, children: [String], context: MarkdownWriteContext) -> [String]? {
        guard let ref = block.props.attachment else { return nil }
        guard let path = context.resolveAttachment(ref) else { return [AttachmentMarkup.notDownloaded(ref)] }
        return ["[\(AttachmentMarkup.bracketed(ref.name))](\(InlineMarkdown.encodedPath(path)))"]
    }
}

/// Файл — `<video src controls></video>`; YouTube и Vimeo — `<iframe data-video>` и ссылка на ролик строкой ниже.
/// Подпись — строкой под ним.
struct VideoWriter: MarkdownBlockKindWriter {
    var kinds: Set<BlockKind> { [.video] }

    func lines(for block: Block, children: [String], context: MarkdownWriteContext) -> [String]? {
        var lines: [String]
        if let url = block.props.url, let link = VideoLink(url: url) {
            let title = block.props.title ?? url.absoluteString
            let poster = AttachmentMarkup.fileAttribute("data-poster", block.props.poster, context: context)
            lines = ["<iframe src=\"\(AttachmentMarkup.attribute(link.plainEmbedURL.absoluteString))\" data-video=\"\(link.sourceName)\"\(poster)></iframe>",
                     "[\(AttachmentMarkup.bracketed(title))](\(url.absoluteString))"]
        } else if let ref = block.props.attachment {
            guard let path = context.resolveAttachment(ref) else { return [AttachmentMarkup.notDownloaded(ref)] }
            lines = ["<video src=\"\(AttachmentMarkup.attribute(InlineMarkdown.encodedPath(path)))\" controls></video>"]
        } else {
            return nil
        }
        let caption = InlineMarkdown.render(block.text).replacingOccurrences(of: "\n", with: "<br>")
        if !caption.isEmpty { lines.append(caption) }
        return lines
    }
}

/// `<a href data-bookmark data-image data-icon>заголовок или адрес</a>`, описание — курсивом строкой ниже.
struct BookmarkWriter: MarkdownBlockKindWriter {
    var kinds: Set<BlockKind> { [.bookmark] }

    func lines(for block: Block, children: [String], context: MarkdownWriteContext) -> [String]? {
        guard let url = block.props.url else { return nil }
        let title = block.props.title ?? url.absoluteString
        let files = AttachmentMarkup.fileAttribute("data-image", block.props.image, context: context)
            + AttachmentMarkup.fileAttribute("data-icon", block.props.iconAttachment, context: context)
        var lines = ["<a href=\"\(AttachmentMarkup.attribute(url.absoluteString))\" data-bookmark\(files)>\(AttachmentMarkup.attribute(title))</a>"]
        if let description = block.props.description?.replacingOccurrences(of: "\n", with: " "), !description.isEmpty {
            let units = Array(description.utf16)
            lines.append("*\(InlineMarkdown.escape(units, range: 0..<units.count))*")
        }
        return lines
    }
}

enum AttachmentMarkup {
    static func notDownloaded(_ ref: AttachmentRef) -> String {
        "[файл не скачан: \(ref.name)]"
    }

    /// ` data-poster="Страница/обложка.jpg"` — копия файла выгружена; нет файла или копии — пусто.
    static func fileAttribute(_ name: String, _ ref: AttachmentRef?, context: MarkdownWriteContext) -> String {
        guard let ref, let path = context.resolveAttachment(ref) else { return "" }
        return " \(name)=\"\(attribute(InlineMarkdown.encodedPath(path)))\""
    }

    /// Значение атрибута HTML: `&`, `<`, `>`, `"` — мнемониками.
    static func attribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Текст в квадратных скобках ссылки или картинки.
    static func bracketed(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    /// Доля без лишних нулей: 0.6, 0.25.
    static func number(_ value: Double) -> String {
        let rounded = (value * 1_000).rounded() / 1_000
        return String(format: "%g", rounded)
    }
}
