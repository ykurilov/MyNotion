import Foundation
import NotesCore

/// Куда ведёт ссылка Markdown: на адрес, на страницу выгрузки (`.md`, `.csv`) или на вложенный файл.
enum NotionLinkTarget: Hashable {
    case url(URL)
    case page(String)
    case file(String)

    /// Адрес из ссылки. Путь внутри выгрузки — раскодированный: `MyNotion%20—/Идеи.md` → `MyNotion —/Идеи.md`.
    init?(destination raw: String) {
        if raw.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) != nil {
            guard let url = URL(string: raw) else { return nil }
            self = .url(url)
            return
        }
        guard !raw.isEmpty, !raw.hasPrefix("#") else { return nil }
        let path = raw.removingPercentEncoding ?? raw
        switch (path as NSString).pathExtension.lowercased() {
        case "": return nil
        case "md", "csv": self = .page(path)
        default: self = .file(path)
        }
    }
}

/// Строка блока после разбора.
struct NotionInlineResult {
    var text: InlineText
    /// Сколько картинок и вложений стало «[файл: имя]».
    var files = 0
    /// Вся строка — одна ссылка и ничего больше: куда она ведёт.
    var soleLink: NotionLinkTarget?
    /// Ссылки на страницы выгрузки внутри текста — упоминания с временным id; импорт заменит его id страницы.
    var pageMentions: [NotionPageMention] = []
}

/// Упоминание страницы выгрузки до импорта: временный id в тексте, путь файла и название из ссылки.
struct NotionPageMention: Hashable, Sendable {
    var placeholder: UUID
    var path: String
    var title: String
}

/// Оформление в строке по правилам CommonMark и GFM: обратная косая черта, код в обратных кавычках, серии `*`, `_`, `~`
/// (алгоритм «process emphasis» спецификации), ссылки и картинки, адреса в угловых скобках, теги `<u>`, `<strong>`…,
/// мнемоники `&amp;`. Зеркало `InlineMarkdown` модуля выгрузки: что он пишет, то здесь читается в то же оформление.
struct NotionInlineParser {
    static func parse(_ source: String) -> NotionInlineResult {
        var parser = NotionInlineParser(source)
        parser.scan()
        parser.processEmphasis(above: 0)
        return parser.result()
    }

    private enum Style: CaseIterable { case bold, italic, strikethrough, underline, code }

    private final class Node {
        enum Kind {
            case text(String)
            case code(String)
            /// Серия `*`, `_` или `~`; сколько знаков осталось несопоставленными — в `count`.
            case delimiter(Character)
            case open(Style)
            case close(Style)
            /// `[` или `![`, ещё не ставшие ссылкой.
            case bracket(isImage: Bool)
            case linkOpen(NotionLinkTarget)
            case linkClose
            /// Знак U+FFFC с атомом: дата из `<time>`.
            case atom(InlineStyle)
        }

        var kind: Kind
        var count = 0
        var originalCount = 0
        var canOpen = false
        var canClose = false

        init(_ kind: Kind) { self.kind = kind }
    }

    private struct Bracket {
        let node: Node
        /// Сколько серий было в стопке, когда открылась скобка: оформление внутри ссылки сопоставляется только выше.
        let delimiterBottom: Int
        var isActive = true
    }

    private let characters: [Character]
    private var position = 0
    private var nodes: [Node] = []
    private var delimiters: [Node] = []
    private var brackets: [Bracket] = []
    private var pendingText = ""
    private var files = 0

    private init(_ source: String) {
        characters = Array(source)
    }

    // MARK: Просмотр строки

    private mutating func scan() {
        while position < characters.count {
            let character = characters[position]
            switch character {
            case "\\": scanBackslash()
            case "`": scanCode()
            case "*", "_", "~": scanDelimiterRun(character)
            case "!" where peek(1) == "[":
                pushBracket(isImage: true)
                position += 2
            case "[":
                pushBracket(isImage: false)
                position += 1
            case "]": scanClosingBracket()
            case "<": scanAngleBracket()
            case "&": scanEntity()
            default:
                pendingText.append(character)
                position += 1
            }
        }
        flushText()
    }

    private func peek(_ offset: Int) -> Character? {
        position + offset < characters.count ? characters[position + offset] : nil
    }

    private mutating func flushText() {
        guard !pendingText.isEmpty else { return }
        nodes.append(Node(.text(pendingText)))
        pendingText = ""
    }

    private mutating func append(_ node: Node) {
        flushText()
        nodes.append(node)
    }

    private mutating func scanBackslash() {
        if let next = peek(1), next.isASCII, next.isPunctuation || next.isSymbol {
            pendingText.append(next)
            position += 2
        } else {
            pendingText.append("\\")
            position += 1
        }
    }

    /// Код: серия обратных кавычек до такой же серии; внутри ничего не разбирается.
    private mutating func scanCode() {
        let length = runLength(of: "`", from: position)
        var search = position + length
        while search < characters.count {
            if characters[search] == "`" {
                let closing = runLength(of: "`", from: search)
                if closing == length {
                    var code = String(characters[(position + length)..<search])
                    if code.count >= 2, code.first == " ", code.last == " ", code.contains(where: { $0 != " " }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    append(Node(.code(code)))
                    position = search + closing
                    return
                }
                search += closing
            } else {
                search += 1
            }
        }
        pendingText += String(repeating: "`", count: length)
        position += length
    }

    private func runLength(of character: Character, from start: Int) -> Int {
        var end = start
        while end < characters.count, characters[end] == character { end += 1 }
        return end - start
    }

    /// Серия знаков оформления и может ли она открывать и закрывать (CommonMark, «left/right-flanking»).
    private mutating func scanDelimiterRun(_ character: Character) {
        let length = runLength(of: character, from: position)
        let before = position > 0 ? characters[position - 1] : nil
        let after = position + length < characters.count ? characters[position + length] : nil
        position += length
        if character == "~", length > 2 {
            pendingText += String(repeating: "~", count: length)
            return
        }
        let leftFlanking = Self.isLeftFlanking(before: before, after: after)
        let rightFlanking = Self.isRightFlanking(before: before, after: after)
        let node = Node(.delimiter(character))
        node.count = length
        node.originalCount = length
        if character == "_" {
            node.canOpen = leftFlanking && (!rightFlanking || Self.characterClass(before) == .punctuation)
            node.canClose = rightFlanking && (!leftFlanking || Self.characterClass(after) == .punctuation)
        } else {
            node.canOpen = leftFlanking
            node.canClose = rightFlanking
        }
        append(node)
        delimiters.append(node)
    }

    private mutating func pushBracket(isImage: Bool) {
        let node = Node(.bracket(isImage: isImage))
        append(node)
        brackets.append(Bracket(node: node, delimiterBottom: delimiters.count))
    }

    /// `]`: если за ней `(адрес)` и есть открытая скобка — ссылка или картинка; иначе знаки остаются текстом.
    private mutating func scanClosingBracket() {
        position += 1
        guard let opener = brackets.last else {
            pendingText.append("]")
            return
        }
        guard opener.isActive, let (destination, end) = linkDestination(from: position) else {
            brackets.removeLast()
            pendingText.append("]")
            return
        }
        flushText()
        brackets.removeLast()
        position = end
        processEmphasis(above: opener.delimiterBottom)
        guard let openerIndex = nodes.firstIndex(where: { $0 === opener.node }) else { return }
        let isImage = if case .bracket(isImage: true) = opener.node.kind { true } else { false }
        let target = NotionLinkTarget(destination: destination)
        if isImage || { if case .file = target { true } else { false } }() {
            // Картинка или вложение: имя файла вместо содержимого ссылки.
            let label = Self.plainText(of: nodes[(openerIndex + 1)...])
            let fileName = destination.isEmpty ? label : ((destination.removingPercentEncoding ?? destination) as NSString).lastPathComponent
            let name = isImage || label.isEmpty ? fileName : label
            nodes.removeSubrange(openerIndex...)
            nodes.append(Node(.text("[файл: \(name)]")))
            files += 1
            return
        }
        if let target {
            opener.node.kind = .linkOpen(target)
            nodes.append(Node(.linkClose))
        } else {
            // Ссылка в никуда (якорь, пустой адрес) — остаётся её текст.
            opener.node.kind = .text("")
        }
        // Ссылка не бывает внутри ссылки.
        for index in brackets.indices {
            if case .bracket(isImage: false) = brackets[index].node.kind { brackets[index].isActive = false }
        }
    }

    /// `(адрес "заголовок")` сразу после `]`: адрес с раскрытыми экранированиями и позиция после `)`.
    private func linkDestination(from start: Int) -> (String, Int)? {
        guard start < characters.count, characters[start] == "(" else { return nil }
        var index = start + 1
        func skipSpaces() { while index < characters.count, characters[index] == " " || characters[index] == "\n" { index += 1 } }
        skipSpaces()
        var destination = ""
        if index < characters.count, characters[index] == "<" {
            index += 1
            while index < characters.count, characters[index] != ">" {
                if characters[index] == "\n" || characters[index] == "<" { return nil }
                if characters[index] == "\\", index + 1 < characters.count, characters[index + 1].isASCII, characters[index + 1].isPunctuation {
                    index += 1
                }
                destination.append(characters[index])
                index += 1
            }
            guard index < characters.count else { return nil }
            index += 1
        } else {
            var depth = 0
            while index < characters.count {
                let character = characters[index]
                if character == " " || character == "\n" { break }
                if character == "\\", index + 1 < characters.count, characters[index + 1].isASCII,
                   characters[index + 1].isPunctuation || characters[index + 1].isSymbol {
                    destination.append(characters[index + 1])
                    index += 2
                    continue
                }
                if character == "(" { depth += 1 }
                if character == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                destination.append(character)
                index += 1
            }
        }
        skipSpaces()
        if index < characters.count, let closing = ([Character("\""): Character("\""), "'": "'", "(": ")"] as [Character: Character])[characters[index]] {
            index += 1
            while index < characters.count, characters[index] != closing {
                if characters[index] == "\\" { index += 1 }
                index += 1
            }
            guard index < characters.count else { return nil }
            index += 1
            skipSpaces()
        }
        guard index < characters.count, characters[index] == ")" else { return nil }
        return (destination, index + 1)
    }

    /// `<https://…>` — ссылка; `<u>`, `<strong>`… — оформление; `<br>` — перенос; прочие теги убираются.
    private mutating func scanAngleBracket() {
        let rest = String(characters[position...].prefix(2_000))
        if let match = rest.range(of: #"^<[A-Za-z][A-Za-z0-9+.\-]{1,31}:[^<>\s]*>"#, options: .regularExpression),
           let url = URL(string: String(rest[match].dropFirst().dropLast())) {
            append(Node(.linkOpen(.url(url))))
            append(Node(.text(url.absoluteString)))
            append(Node(.linkClose))
            position += rest[match].count
            return
        }
        if let match = rest.range(of: #"^<[A-Za-z0-9.!#$%&'*+/=?^_`{|}~\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)*>"#,
                                  options: .regularExpression),
           let url = URL(string: "mailto:" + rest[match].dropFirst().dropLast()) {
            append(Node(.linkOpen(.url(url))))
            append(Node(.text(String(rest[match].dropFirst().dropLast()))))
            append(Node(.linkClose))
            position += rest[match].count
            return
        }
        if let match = rest.range(of: #"^<time\s[^<>]*>[^<]*</time>"#, options: .regularExpression),
           let date = NotionDates.date(fromTimeTag: String(rest[match])) {
            append(Node(.atom(.date(date))))
            position += rest[match].count
            return
        }
        if let match = rest.range(of: #"^</?([A-Za-z][A-Za-z0-9\-]*)(?:\s[^<>]*)?/?>"#, options: .regularExpression) {
            let tag = String(rest[match])
            let isClosing = tag.hasPrefix("</")
            let name = tag.dropFirst(isClosing ? 2 : 1).prefix { $0.isLetter || $0.isNumber || $0 == "-" }.lowercased()
            position += tag.count
            if name == "br" {
                pendingText.append("\n")
            } else if let style = Self.tagStyles[name] {
                append(Node(isClosing ? .close(style) : .open(style)))
            }
            return
        }
        pendingText.append("<")
        position += 1
    }

    private static let tagStyles: [String: Style] = [
        "u": .underline, "ins": .underline, "strong": .bold, "b": .bold, "em": .italic, "i": .italic,
        "del": .strikethrough, "s": .strikethrough, "strike": .strikethrough, "code": .code,
    ]

    private mutating func scanEntity() {
        let rest = String(characters[position...].prefix(40))
        guard let match = rest.range(of: #"^&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});"#, options: .regularExpression)
        else {
            pendingText.append("&")
            position += 1
            return
        }
        let body = rest[match].dropFirst().dropLast()
        var decoded: String?
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            decoded = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        } else if body.hasPrefix("#") {
            decoded = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        } else {
            decoded = Self.namedEntities[String(body)]
        }
        if let decoded {
            pendingText += decoded
            position += rest[match].count
        } else {
            pendingText.append("&")
            position += 1
        }
    }

    private static let namedEntities = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
        "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»", "hellip": "…", "times": "×", "trade": "™",
    ]

    // MARK: Сопоставление серий (CommonMark, «process emphasis»)

    private mutating func processEmphasis(above bottom: Int) {
        var closerIndex = bottom
        while closerIndex < delimiters.count {
            let closer = delimiters[closerIndex]
            guard closer.canClose, case .delimiter(let mark) = closer.kind else {
                closerIndex += 1
                continue
            }
            var openerIndex = closerIndex - 1
            while openerIndex >= bottom {
                let opener = delimiters[openerIndex]
                if case .delimiter(mark) = opener.kind, opener.canOpen, Self.canMatch(opener, closer, mark: mark) { break }
                openerIndex -= 1
            }
            guard openerIndex >= bottom else {
                if closer.canOpen { closerIndex += 1 } else { delimiters.remove(at: closerIndex) }
                continue
            }
            let opener = delimiters[openerIndex]
            let used: Int
            let style: Style
            if mark == "~" {
                used = closer.count
                style = .strikethrough
            } else {
                used = opener.count >= 2 && closer.count >= 2 ? 2 : 1
                style = used == 2 ? .bold : .italic
            }
            if let index = nodes.firstIndex(where: { $0 === opener }) { nodes.insert(Node(.open(style)), at: index + 1) }
            if let index = nodes.firstIndex(where: { $0 === closer }) { nodes.insert(Node(.close(style)), at: index) }
            // Серии между ними уже ничего не откроют и не закроют: остаются текстом.
            delimiters.removeSubrange((openerIndex + 1)..<closerIndex)
            closerIndex = openerIndex + 1
            opener.count -= used
            closer.count -= used
            if opener.count == 0 {
                delimiters.remove(at: openerIndex)
                closerIndex -= 1
            }
            if closer.count == 0 { delimiters.remove(at: closerIndex) }
        }
        delimiters.removeSubrange(min(bottom, delimiters.count)...)
    }

    /// Правило «трёх» CommonMark для `*` и `_`; зачёркивание GFM — только серии одной длины.
    private static func canMatch(_ opener: Node, _ closer: Node, mark: Character) -> Bool {
        if mark == "~" { return opener.count == closer.count }
        let isOddMatch = (opener.canClose || closer.canOpen)
            && (opener.originalCount + closer.originalCount) % 3 == 0
            && !(opener.originalCount % 3 == 0 && closer.originalCount % 3 == 0)
        return !isOddMatch
    }

    // MARK: Итог

    private func result() -> NotionInlineResult {
        var units: [UInt16] = []
        var depth: [Style: Int] = [:]
        var starts: [Style: Int] = [:]
        var links: [(NotionLinkTarget, Int)] = []
        var runs: [StyledRun] = []
        var pageMentions: [NotionPageMention] = []
        // Строка целиком из одной ссылки на страницу — блок-подстраница, а не упоминание.
        let sole = soleLink()
        let mentionsPages: Bool = if case .page? = sole { false } else { true }
        var skipUntil: Int?
        func appendAtom(_ style: InlineStyle) {
            runs.append(StyledRun(start: units.count, length: 1, style: style))
            units.append(InlineText.objectReplacementCharacter)
        }

        func open(_ style: Style) {
            depth[style, default: 0] += 1
            if depth[style] == 1 { starts[style] = units.count }
        }
        func close(_ style: Style) {
            guard let current = depth[style], current > 0 else { return }
            depth[style] = current - 1
            if current == 1, let start = starts[style], units.count > start {
                runs.append(StyledRun(start: start, length: units.count - start, style: Self.inlineStyle(style)))
            }
        }

        for (index, node) in nodes.enumerated() {
            if let end = skipUntil {
                if index < end { continue }
                skipUntil = nil
                if index == end { continue }
            }
            switch node.kind {
            case .linkOpen(.page(let path)) where mentionsPages:
                // Ссылка на страницу внутри текста — упоминание: текст ссылки становится названием.
                guard let close = Self.matchingClose(of: index, in: nodes) else { links.append((.page(path), units.count)); continue }
                let mention = NotionPageMention(placeholder: UUID(), path: path, title: Self.plainText(of: nodes[(index + 1)..<close]))
                pageMentions.append(mention)
                appendAtom(.mention(mention.placeholder))
                skipUntil = close
            case .text(let text):
                for piece in NotionDates.split(text) {
                    switch piece {
                    case .text(let plain): units += plain.utf16
                    case .date(let date): appendAtom(.date(date))
                    }
                }
            case .atom(let style): appendAtom(style)
            case .code(let code):
                open(.code)
                units += code.utf16
                close(.code)
            case .delimiter(let mark): units += String(repeating: mark, count: node.count).utf16
            case .open(let style): open(style)
            case .close(let style): close(style)
            case .bracket(let isImage): units += (isImage ? "![" : "[").utf16
            case .linkOpen(let target): links.append((target, units.count))
            case .linkClose:
                guard let (target, start) = links.popLast() else { continue }
                if case .url(let url) = target, units.count > start {
                    runs.append(StyledRun(start: start, length: units.count - start, style: .link(url)))
                }
            }
        }
        for style in Style.allCases where depth[style, default: 0] > 0 {
            depth[style] = 1
            close(style)
        }
        return NotionInlineResult(text: InlineText(String(decoding: units, as: UTF16.self), runs: runs).normalized(),
                                  files: files, soleLink: sole, pageMentions: pageMentions)
    }

    /// Закрытие ссылки, открытой узлом `index`.
    private static func matchingClose(of index: Int, in nodes: [Node]) -> Int? {
        var depth = 0
        for position in (index + 1)..<nodes.count {
            switch nodes[position].kind {
            case .linkOpen: depth += 1
            case .linkClose:
                if depth == 0 { return position }
                depth -= 1
            default: break
            }
        }
        return nil
    }

    /// Ссылка, которая и есть вся строка (пробелы по краям не в счёт).
    private func soleLink() -> NotionLinkTarget? {
        let isBlank: (Node) -> Bool = { node in
            if case .text(let text) = node.kind { text.allSatisfy(\.isWhitespace) } else { false }
        }
        guard let first = nodes.firstIndex(where: { !isBlank($0) }), let last = nodes.lastIndex(where: { !isBlank($0) }),
              case .linkOpen(let target) = nodes[first].kind, case .linkClose = nodes[last].kind
        else { return nil }
        let linkCount = nodes[first...last].count { if case .linkOpen = $0.kind { true } else { false } }
        return linkCount == 1 ? target : nil
    }

    private static func inlineStyle(_ style: Style) -> InlineStyle {
        switch style {
        case .bold: .bold
        case .italic: .italic
        case .strikethrough: .strikethrough
        case .underline: .underline
        case .code: .code
        }
    }

    private static func plainText(of nodes: ArraySlice<Node>) -> String {
        nodes.map { node in
            switch node.kind {
            case .text(let text), .code(let text): text
            case .delimiter(let mark): String(repeating: mark, count: node.count)
            default: ""
            }
        }.joined()
    }

    // MARK: Прилегание серий (как в `InlineMarkdown` выгрузки)

    private enum CharacterClass { case whitespace, punctuation, other }

    private static func characterClass(_ character: Character?) -> CharacterClass {
        guard let character else { return .whitespace }
        if character.isWhitespace { return .whitespace }
        if character.isPunctuation || character.isSymbol { return .punctuation }
        return .other
    }

    private static func isLeftFlanking(before: Character?, after: Character?) -> Bool {
        let next = characterClass(after)
        return next != .whitespace && (next != .punctuation || characterClass(before) != .other)
    }

    private static func isRightFlanking(before: Character?, after: Character?) -> Bool {
        let previous = characterClass(before)
        return previous != .whitespace && (previous != .punctuation || characterClass(after) != .other)
    }
}
