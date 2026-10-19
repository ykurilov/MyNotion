import Foundation
import LinkPreview
import NotesCore

/// Картинка, файл, видео, закладка из Markdown Notion и нашей выгрузки (contracts/markdown-and-notion.md).
/// Файл блока — путь в выгрузке (`attachmentPath`); копирует его во вложения импорт (`NotionImporter`).
/// Ссылка на сайт на своей строке становится закладкой или видео там же, после поиска страниц выгрузки.

/// `![подпись](Страница/картинка.png)` и `[имя](Страница/файл.pdf)` — одни на своей строке.
struct MediaLinkReader: NotionBlockReader {
    func read(_ lines: ArraySlice<String>, at index: Int) -> NotionBlockReading? {
        guard AttachmentMarkup.standsAlone(lines, at: index),
              let match = lines[index].trimmingCharacters(in: .whitespaces).wholeMatch(of: AttachmentMarkup.linkLine),
              case .file(let path)? = NotionLinkTarget(destination: String(match.output.3)) else { return nil }
        let isImage = !match.output.1.isEmpty
        var block = ParsedBlock(kind: isImage ? .image : .file)
        // Картинку без подписи Notion пишет с именем файла вместо подписи.
        let caption = NotionInlineParser.parse(String(match.output.2)).text
        if isImage, caption.string != (path as NSString).lastPathComponent { block.text = caption }
        block.attachmentPath = path
        return NotionBlockReading(blocks: [block], nextIndex: index + 1)
    }
}

/// `<img src alt data-width>` — картинка уже́ колонки.
struct ImageTagReader: NotionBlockReader {
    func read(_ lines: ArraySlice<String>, at index: Int) -> NotionBlockReading? {
        guard let attributes = AttachmentMarkup.tag("img", in: lines[index]), let source = attributes["src"],
              case .file(let path)? = NotionLinkTarget(destination: source) else { return nil }
        var block = ParsedBlock(kind: .image, text: InlineText(attributes["alt"] ?? ""))
        block.attachmentPath = path
        if let width = attributes["data-width"].flatMap(Double.init), width > 0, width < 1 { block.props.width = width }
        return NotionBlockReading(blocks: [block], nextIndex: index + 1)
    }
}

/// `<video src controls></video>` и подпись строкой ниже.
struct VideoTagReader: NotionBlockReader {
    func read(_ lines: ArraySlice<String>, at index: Int) -> NotionBlockReading? {
        guard let attributes = AttachmentMarkup.tag("video", in: lines[index]), let source = attributes["src"],
              case .file(let path)? = NotionLinkTarget(destination: source) else { return nil }
        var block = ParsedBlock(kind: .video)
        block.props.videoSource = .file
        block.attachmentPath = path
        var next = index + 1
        if let caption = AttachmentMarkup.captionLine(lines, at: next) {
            block.text = caption
            next += 1
        }
        return NotionBlockReading(blocks: [block], nextIndex: next)
    }
}

/// `<iframe src data-video="youtube"></iframe>`, ссылка на ролик строкой ниже, затем подпись.
struct EmbeddedVideoReader: NotionBlockReader {
    func read(_ lines: ArraySlice<String>, at index: Int) -> NotionBlockReading? {
        guard let attributes = AttachmentMarkup.tag("iframe", in: lines[index]), attributes["data-video"] != nil,
              let embed = attributes["src"].flatMap(URL.init(string:)), let link = VideoLink(url: embed) else { return nil }
        var block = ParsedBlock(kind: .video)
        block.props.videoSource = link.sourceName == "vimeo" ? .vimeo : .youtube
        block.props.url = link.watchURL
        var next = index + 1
        if next < lines.endIndex, let match = lines[next].trimmingCharacters(in: .whitespaces).wholeMatch(of: AttachmentMarkup.linkLine),
           match.output.1.isEmpty, let url = URL(string: String(match.output.3)) {
            block.props.url = url
            let title = NotionInlineParser.parse(String(match.output.2)).text.string
            if title != url.absoluteString, !title.isEmpty { block.props.title = title }
            next += 1
        }
        if let caption = AttachmentMarkup.captionLine(lines, at: next) {
            block.text = caption
            next += 1
        }
        return NotionBlockReading(blocks: [block], nextIndex: next)
    }
}

/// `<a href data-bookmark>заголовок</a>`, описание курсивом строкой ниже.
struct BookmarkTagReader: NotionBlockReader {
    func read(_ lines: ArraySlice<String>, at index: Int) -> NotionBlockReading? {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        guard let match = line.wholeMatch(of: /<a\s([^>]*\bdata-bookmark\b[^>]*)>([\s\S]*?)<\/a>/.ignoresCase()),
              let url = AttachmentMarkup.attributes(String(match.output.1))["href"].flatMap(URL.init(string:)) else { return nil }
        var block = ParsedBlock(kind: .bookmark)
        block.props.url = url
        let title = HTMLMetadata.decodeEntities(String(match.output.2))
        if !title.isEmpty, title != url.absoluteString { block.props.title = title }
        var next = index + 1
        if next < lines.endIndex {
            let candidate = lines[next].trimmingCharacters(in: .whitespaces)
            if candidate.count > 2, candidate.hasPrefix("*"), candidate.hasSuffix("*"), !candidate.hasPrefix("**") {
                block.props.description = NotionInlineParser.parse(String(candidate.dropFirst().dropLast())).text.string
                next += 1
            }
        }
        return NotionBlockReading(blocks: [block], nextIndex: next)
    }
}

/// Голый адрес на своей строке (`https://vimeo.com/…`) — как ссылка на своей строке: импорт сделает из него
/// видео или закладку.
struct BareAddressReader: NotionBlockReader {
    func read(_ lines: ArraySlice<String>, at index: Int) -> NotionBlockReading? {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        guard AttachmentMarkup.standsAlone(lines, at: index), line.wholeMatch(of: /https?:\/\/\S+/) != nil,
              let url = URL(string: line), url.host != nil else { return nil }
        let text = InlineText(line, runs: [StyledRun(start: 0, length: (line as NSString).length, style: .link(url))])
        return NotionBlockReading(blocks: [ParsedBlock(kind: .paragraph, text: text, standaloneURL: url)], nextIndex: index + 1)
    }
}

enum AttachmentMarkup {
    /// `![подпись](путь)` или `[имя](путь)` — вся строка.
    nonisolated(unsafe) static let linkLine = /(!?)\[((?:\\.|[^\]\\])*)\]\(<?([^)\s>]+)>?\)/

    /// Строка блока: до неё и после — пустая строка или край страницы.
    static func standsAlone(_ lines: ArraySlice<String>, at index: Int) -> Bool {
        let before = index == lines.startIndex || NotionMarkdownParser.isBlank(lines[index - 1])
        let after = index + 1 >= lines.endIndex || NotionMarkdownParser.isBlank(lines[index + 1])
        return before && after
    }

    /// Атрибуты тега `name`, если строка — этот тег (с закрывающим или без).
    static func tag(_ name: String, in line: String) -> [String: String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("<\(name) ") || trimmed.lowercased().hasPrefix("<\(name)\t"),
              let end = trimmed.firstIndex(of: ">") else { return nil }
        let rest = trimmed[trimmed.index(after: end)...].trimmingCharacters(in: .whitespaces).lowercased()
        guard rest.isEmpty || rest == "</\(name)>" else { return nil }
        return attributes(String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: name.count + 1)..<end]))
    }

    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in text.matches(of: /([A-Za-z_:\-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/) {
            let key = match.output.1.lowercased()
            let value = match.output.2 ?? match.output.3 ?? match.output.4 ?? ""
            if result[key] == nil { result[key] = HTMLMetadata.decodeEntities(String(value)) }
        }
        return result
    }

    /// Подпись под видео: непустая строка сразу под блоком, не тег.
    static func captionLine(_ lines: ArraySlice<String>, at index: Int) -> InlineText? {
        guard index < lines.endIndex, !NotionMarkdownParser.isBlank(lines[index]) else { return nil }
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("<") || line.hasPrefix("<br") else { return nil }
        return NotionInlineParser.parse(line).text
    }
}
