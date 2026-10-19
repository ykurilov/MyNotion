import Foundation
import NotesCore

/// Что при разборе пришлось упростить до простого текста (FR-026). Слова — для итога, простые, без терминов Notion.
public enum NotionSimplification: String, CaseIterable, Sendable, Codable, Hashable {
    case table, file, quote, callout, code, toggle, divider, equation, embed

    /// «таблицы (2)», «картинки и файлы (3) — вместо них их имена».
    public func title(count: Int) -> String {
        let (name, note): (String, String?) = switch self {
        case .table: ("таблицы", "по строке на абзац")
        case .file: ("картинки и файлы", "вместо них их имена")
        case .quote: ("цитаты", nil)
        case .callout: ("выделенные блоки со значком", nil)
        case .code: ("блоки кода", nil)
        case .toggle: ("раскрывающиеся списки", "текст внутри показан сразу")
        case .divider: ("разделительные линии", "убраны")
        case .equation: ("формулы", "записаны как текст")
        case .embed: ("встроенные видео и сайты", "вместо них их адреса")
        }
        return name + (count > 1 ? " (\(count))" : "") + (note.map { " — " + $0 } ?? "")
    }
}

/// Блок после разбора: ещё не запись базы — без страницы, ключа порядка и меток часов.
public struct ParsedBlock: Sendable, Hashable {
    public var kind: BlockKind
    public var text: InlineText
    public var indent: Int
    public var isChecked: Bool
    /// Только у `.pageLink`: путь файла страницы из ссылки, раскодированный (`Папка/Страница.md`). Найдёт ли импорт
    /// такую страницу, разбор не знает: не нашёл — блок станет абзацем с названием.
    public var pagePath: String?
    /// Абзац — одна ссылка на адрес и ничего больше (например, на notion.so): импорт может узнать в нём страницу выгрузки.
    public var standaloneURL: URL?
    /// Цвет и свойства блоков 002.
    public var color: BlockColor
    public var props: BlockProps
    /// Блоки внутри контейнера (колонки, таблица): их `containerId` — этот блок.
    public var contained: [ParsedBlock]
    /// Упоминания страниц в тексте: импорт найдёт их страницы (`NotionImporter.resolvingMentions`).
    var mentions: [NotionPageMention] = []

    public init(kind: BlockKind, text: InlineText = .empty, indent: Int = 0, isChecked: Bool = false,
                pagePath: String? = nil, standaloneURL: URL? = nil, color: BlockColor = .none, props: BlockProps = .empty,
                contained: [ParsedBlock] = []) {
        self.kind = kind
        self.text = text
        self.indent = indent
        self.isChecked = isChecked
        self.pagePath = pagePath
        self.standaloneURL = standaloneURL
        self.color = color
        self.props = props
        self.contained = contained
    }
}

/// Страница после разбора: название и иконка из первой строки `# 📘 Название`, блоки и что упрощено.
public struct ParsedNotionPage: Sendable, Hashable {
    public var title: String?
    public var icon: String?
    public var blocks: [ParsedBlock]
    public var simplifications: [NotionSimplification: Int]
}

/// Разбор подмножества Markdown, которое пишет Notion (и наша выгрузка), в блоки MyNotion по таблице
/// contracts/files-import-export.md (research R11). Своё, а не общий разбор Markdown: строк немного, а итог
/// всё равно переводить в наши блоки. Оформление в строке разбирает `NotionInlineParser`.
public struct NotionMarkdownParser: Sendable {
    public init() {}

    public func parse(_ markdown: String) -> ParsedNotionPage {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[0] = String(first.dropFirst()) }

        var index = 0
        while index < lines.count, Self.isBlank(lines[index]) { index += 1 }
        var title: String?
        var icon: String?
        if index < lines.count, let heading = Self.heading(lines[index]), heading.level == 1 {
            (icon, title) = Self.splitIcon(NotionInlineParser.parse(heading.text).text.string)
            index += 1
        }
        var builder = PageBuilder()
        builder.consume(lines[index...])
        return ParsedNotionPage(title: title, icon: icon, blocks: builder.blocks, simplifications: builder.simplifications)
    }

    // MARK: Строки

    static func isBlank(_ line: some StringProtocol) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 } else if character == "\t" { count += 4 - count % 4 } else { break }
        }
        return count
    }

    static func heading(_ line: String) -> (level: Int, text: String)? {
        guard leadingSpaces(line) <= 3 else { return nil }
        let trimmed = line.drop { $0 == " " }
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return (min(hashes, 3), rest.trimmingCharacters(in: .whitespaces))
    }

    /// `📘 Название` → иконка и название. Иконка — один эмодзи, как требует страница (data-model.md).
    static func splitIcon(_ title: String) -> (String?, String) {
        guard let first = title.first, title.dropFirst().first == " " else { return (nil, title) }
        let scalars = first.unicodeScalars
        guard scalars.contains(where: \.properties.isEmojiPresentation) || scalars.contains("\u{FE0F}") else { return (nil, title) }
        return (String(first), String(title.dropFirst(2)))
    }
}

/// Сборка блоков страницы строка за строкой.
private struct PageBuilder {
    private(set) var blocks: [ParsedBlock] = []
    private(set) var simplifications: [NotionSimplification: Int] = [:]

    /// Абзац или пункт списка, строки которого ещё собираются.
    private struct OpenBlock {
        var kind: BlockKind
        var indent = 0
        var isChecked = false
        var lines: [String]
    }

    private var open: OpenBlock?
    /// Пустые строки после последнего блока: лишняя — пустой абзац.
    private var blankLines = 0
    /// Колонки текста открытых пунктов списка: по ним считается вложенность.
    private var listColumns: [Int] = []

    mutating func consume(_ lines: ArraySlice<String>) {
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1
            if NotionMarkdownParser.isBlank(line) {
                closeOpenBlock()
                blankLines += 1
                continue
            }
            if let reading = NotionBlockReaders.all.lazy.compactMap({ $0.read(lines, at: index - 1) }).first {
                closeOpenBlock()
                for block in reading.blocks { emit(block) }
                index = max(reading.nextIndex, index)
                continue
            }
            if let fence = Self.fence(trimmed) {
                closeOpenBlock()
                let indentation = NotionMarkdownParser.leadingSpaces(line)
                var code: [String] = []
                while index < lines.endIndex {
                    let candidate = lines[index]
                    index += 1
                    if candidate.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    code.append(String(candidate.dropFirst(min(indentation, NotionMarkdownParser.leadingSpaces(candidate)))))
                }
                emit(ParsedBlock(kind: .paragraph, text: InlineText(code.joined(separator: "\n"))), simplified: .code)
                continue
            }
            if trimmed.hasPrefix("$$") {
                closeOpenBlock()
                var formula: [String] = []
                if trimmed.count > 4, trimmed.hasSuffix("$$") {
                    formula = [String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)]
                } else {
                    let first = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    if !first.isEmpty { formula.append(first) }
                    while index < lines.endIndex {
                        let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                        index += 1
                        if candidate.hasSuffix("$$") {
                            let last = candidate.dropLast(2).trimmingCharacters(in: .whitespaces)
                            if !last.isEmpty { formula.append(last) }
                            break
                        }
                        formula.append(candidate)
                    }
                }
                emit(ParsedBlock(kind: .paragraph, text: InlineText(formula.joined(separator: "\n"))), simplified: .equation)
                continue
            }
            if trimmed.hasPrefix("|"), index < lines.endIndex, Self.isTableSeparator(lines[index]) {
                closeOpenBlock()
                let header = Self.tableCells(trimmed)
                index += 1
                var rows: [String] = []
                while index < lines.endIndex, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let cells = Self.tableCells(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                    let pairs = zip(header, cells).filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }
                    if !pairs.isEmpty { rows.append(pairs.joined(separator: "\n")) }
                }
                for row in rows { emit(ParsedBlock(kind: .paragraph, text: InlineText(row))) }
                count(.table)
                continue
            }
            if let html = Self.htmlBlock(trimmed) {
                closeOpenBlock()
                switch html {
                case .boundary(let simplification):
                    if let simplification { count(simplification) }
                    // Обёртка выноски или переключателя — не пустой абзац.
                    blankLines = 0
                case .summary(let text):
                    emit(paragraph(from: [text]))
                case .embed(let text):
                    if !text.isEmpty { emit(ParsedBlock(kind: .paragraph, text: InlineText(text))) }
                    count(.embed)
                }
                continue
            }
            if let heading = NotionMarkdownParser.heading(line) {
                closeOpenBlock()
                listColumns = []
                let level: BlockKind = heading.level == 1 ? .heading1 : heading.level == 2 ? .heading2 : .heading3
                let parsed = NotionInlineParser.parse(heading.text)
                note(files: parsed.files)
                var headingBlock = ParsedBlock(kind: level, text: parsed.text)
                headingBlock.mentions = parsed.pageMentions
                emit(headingBlock)
                continue
            }
            if trimmed.hasPrefix(">") {
                closeOpenBlock()
                var quote = [Self.quoteText(trimmed)]
                while index < lines.endIndex, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(Self.quoteText(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                emit(paragraph(from: quote), simplified: .quote)
                continue
            }
            if Self.isThematicBreak(trimmed) {
                closeOpenBlock()
                count(.divider)
                blankLines = 0
                continue
            }
            if let item = Self.listItem(line) {
                closeOpenBlock()
                while let column = listColumns.last, item.start < column { listColumns.removeLast() }
                let indent = min(listColumns.count, Block.indentRange.upperBound)
                listColumns.append(item.contentColumn)
                open = OpenBlock(kind: item.kind, indent: indent, isChecked: item.isChecked, lines: [item.text])
                continue
            }
            // Пустая строка закрывает блок, поэтому открытый блок — без пустых строк перед этой.
            if open != nil {
                open?.lines.append(trimmed)
                continue
            }
            closeOpenBlock()
            if NotionMarkdownParser.leadingSpaces(line) == 0 { listColumns = [] }
            open = OpenBlock(kind: .paragraph, lines: [trimmed])
        }
        closeOpenBlock()
    }

    // MARK: Блоки

    private mutating func emit(_ block: ParsedBlock, simplified: NotionSimplification? = nil) {
        if !blocks.isEmpty, blankLines > 1 {
            blocks += Array(repeating: ParsedBlock(kind: .paragraph), count: blankLines - 1)
        }
        blocks.append(block)
        blankLines = 0
        if let simplified { count(simplified) }
    }

    private mutating func closeOpenBlock() {
        guard let block = open else { return }
        open = nil
        if block.kind == .paragraph {
            emit(paragraph(from: block.lines))
        } else {
            let parsed = NotionInlineParser.parse(Self.joined(block.lines))
            note(files: parsed.files)
            var parsedBlock = ParsedBlock(kind: block.kind, text: parsed.text, indent: block.indent, isChecked: block.isChecked)
            parsedBlock.mentions = parsed.pageMentions
            emit(parsedBlock)
        }
    }

    /// Абзац; строка из одной ссылки на страницу — блок pageLink, на адрес — абзац с пометкой адреса.
    private mutating func paragraph(from lines: [String]) -> ParsedBlock {
        let parsed = NotionInlineParser.parse(Self.joined(lines))
        note(files: parsed.files)
        switch parsed.soleLink {
        case .page(let path)?: return ParsedBlock(kind: .pageLink, text: InlineText(parsed.text.string), pagePath: path)
        case .url(let url)?: return ParsedBlock(kind: .paragraph, text: parsed.text, standaloneURL: url)
        default:
            var block = ParsedBlock(kind: .paragraph, text: parsed.text)
            block.mentions = parsed.pageMentions
            return block
        }
    }

    private mutating func note(files: Int) {
        if files > 0 { simplifications[.file, default: 0] += files }
    }

    private mutating func count(_ simplification: NotionSimplification) {
        simplifications[simplification, default: 0] += 1
    }

    /// Строки блока через перенос: два пробела или «\» в конце строки — тот же перенос, в текст не попадают.
    private static func joined(_ lines: [String]) -> String {
        lines.map { line in
            var line = Substring(line)
            while line.last == " " || line.last == "\t" { line.removeLast() }
            if line.hasSuffix("\\"), !line.hasSuffix("\\\\"), line.count > 1 { line.removeLast() }
            return String(line)
        }.joined(separator: "\n")
    }

    // MARK: Виды строк

    private struct ListItem {
        var kind: BlockKind
        var isChecked: Bool
        /// Где начинается знак пункта.
        var start: Int
        /// Колонка текста пункта: строка, начатая не левее, вложена в него.
        var contentColumn: Int
        var text: String
    }

    /// `- `, `* `, `+ `, `1. `, `1) `, затем у маркера — `[ ]`, `[x]`.
    private static func listItem(_ line: String) -> ListItem? {
        let start = NotionMarkdownParser.leadingSpaces(line)
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard let first = body.first else { return nil }
        var markerLength: Int
        var kind: BlockKind
        if first == "-" || first == "*" || first == "+" {
            markerLength = 1
            kind = .bulletItem
        } else {
            let digits = body.prefix { $0.isASCII && $0.isNumber }.count
            guard (1...9).contains(digits), let delimiter = body.dropFirst(digits).first, delimiter == "." || delimiter == ")" else { return nil }
            markerLength = digits + 1
            kind = .numberedItem
        }
        let afterMarker = body.dropFirst(markerLength)
        guard afterMarker.isEmpty || afterMarker.first == " " || afterMarker.first == "\t" else { return nil }
        var text = afterMarker.drop { $0 == " " || $0 == "\t" }
        var isChecked = false
        if kind == .bulletItem, text.count >= 3, text.hasPrefix("["), let mark = text.dropFirst().first,
           mark == " " || mark == "x" || mark == "X", text.dropFirst(2).first == "]",
           text.count == 3 || text.dropFirst(3).first == " " || text.dropFirst(3).first == "\t" {
            kind = .checkbox
            isChecked = mark != " "
            text = text.dropFirst(3).drop { $0 == " " || $0 == "\t" }
        }
        return ListItem(kind: kind, isChecked: isChecked, start: start, contentColumn: start + markerLength + 1, text: String(text))
    }

    private static func fence(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            let length = trimmed.prefix { $0 == marker.first }.count
            let fence = String(repeating: marker.first!, count: length)
            // У «```» в строке открытия не бывает обратных кавычек дальше: иначе это код в строке.
            if marker == "```", trimmed.dropFirst(length).contains("`") { return nil }
            return fence
        }
        return nil
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard let mark = trimmed.first, mark == "-" || mark == "*" || mark == "_" else { return false }
        let compact = trimmed.filter { $0 != " " && $0 != "\t" }
        return compact.count >= 3 && compact.allSatisfy { $0 == mark }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        line.range(of: #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#, options: .regularExpression) != nil && line.contains("|")
    }

    /// Ячейки строки таблицы: `\|` внутри ячейки — сама черта; оформление ячеек упрощается до текста.
    private static func tableCells(_ trimmed: String) -> [String] {
        var row = Substring(trimmed)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in row {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        return cells.map { NotionInlineParser.parse($0.trimmingCharacters(in: .whitespaces)).text.string }
    }

    private static func quoteText(_ trimmed: String) -> String {
        let rest = trimmed.dropFirst()
        return String(rest.first == " " ? rest.dropFirst() : rest)
    }

    private enum HTMLBlock {
        /// Строка-обёртка (`<aside>`, `</details>`): сама в текст не идёт.
        case boundary(NotionSimplification?)
        case summary(String)
        case embed(String)
    }

    /// Теги оформления в строке — часть абзаца, а не HTML-блок.
    private static let inlineTags: Set<String> = ["u", "ins", "strong", "b", "em", "i", "del", "s", "strike", "code", "span",
                                                  "a", "br", "mark", "sub", "sup", "small", "kbd"]

    private static func htmlBlock(_ trimmed: String) -> HTMLBlock? {
        // Имя тега, за которым пробел, «>» или «/»: `<https://…>` — адрес, а не тег.
        guard let match = trimmed.range(of: #"^</?[A-Za-z][A-Za-z0-9\-]*(?=[\s/>]|$)"#, options: .regularExpression) else { return nil }
        let name = trimmed[match].drop { $0 == "<" || $0 == "/" }.lowercased()
        guard !inlineTags.contains(name) else { return nil }
        let isClosing = trimmed.hasPrefix("</")
        switch name {
        case "aside": return .boundary(isClosing ? nil : .callout)
        case "details": return .boundary(isClosing ? nil : .toggle)
        case "summary":
            let inner = trimmed.replacingOccurrences(of: #"</?summary[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            return .summary(inner.trimmingCharacters(in: .whitespaces))
        default:
            let text = NotionInlineParser.parse(trimmed).text.string.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return .embed(text) }
            let source = trimmed.range(of: #"(?:src|href)="([^"]*)""#, options: .regularExpression)
                .map { String(trimmed[$0].drop { $0 != "\"" }.dropFirst().dropLast()) } ?? ""
            return .embed(source)
        }
    }
}
