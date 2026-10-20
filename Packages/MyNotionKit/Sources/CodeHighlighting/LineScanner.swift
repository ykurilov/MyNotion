/// Токен строки кода: отрезок в единицах UTF-16 от начала строки и его вид.
public struct CodeToken: Sendable, Hashable {
    public var range: Range<Int>
    public var kind: CodeTokenKind

    public init(_ range: Range<Int>, _ kind: CodeTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// Состояние на конце строки (research R5): внутри многострочного комментария, строки или ограды Markdown.
/// Следующая строка разбирается с него; совпало с прежним — дальше перекрашивать незачем.
public enum LineState: Sendable, Hashable {
    case normal
    /// Номер вида комментария в `blockComments` языка.
    case blockComment(Int)
    /// Номер вида строки в `strings` языка.
    case string(Int)
    /// Внутри ``` в Markdown.
    case markdownFence
}

/// Разбор одной строки кода по таблице языка.
public struct LineScanner: Sendable {
    public let language: LanguageDefinition
    private let lineComments: [[UInt16]]
    private let blockComments: [(open: [UInt16], close: [UInt16])]
    private let strings: [(open: [UInt16], close: [UInt16], escape: UInt16?, multiline: Bool)]
    private let extras: Set<UInt16>

    public init(language: LanguageDefinition) {
        self.language = language
        lineComments = language.lineComments.map { Array($0.utf16) }
        blockComments = language.blockComments.map { (Array($0.open.utf16), Array($0.close.utf16)) }
        // Длинные открытия — раньше: `"""` прежде `"`.
        strings = language.strings
            .map { (Array($0.open.utf16), Array($0.close.utf16), $0.escape.flatMap { $0.utf16.first }, $0.multiline) }
        extras = Set(language.identifierExtras.compactMap { $0.utf16.first })
    }

    public func scan(_ line: String, from state: LineState = .normal) -> (tokens: [CodeToken], end: LineState) {
        scan(Array(line.utf16), from: state)
    }

    public func scan(_ units: [UInt16], from state: LineState = .normal) -> (tokens: [CodeToken], end: LineState) {
        // «Простой текст» не подсвечивается.
        guard language != .plain else { return ([], .normal) }
        var cursor = Cursor(units: units)
        var tokens: [CodeToken] = []
        let count = units.count

        // Продолжение с прошлой строки.
        switch state {
        case .normal:
            break
        case .blockComment(let kind):
            guard let end = cursor.find(blockComments[kind].close, from: 0) else { return ([CodeToken(0..<count, .comment)], state) }
            tokens.append(CodeToken(0..<end, .comment))
            cursor.position = end
        case .string(let kind):
            let rule = strings[kind]
            guard let end = cursor.findClose(rule.close, escape: rule.escape, from: 0) else { return ([CodeToken(0..<count, .string)], state) }
            tokens.append(CodeToken(0..<end, .string))
            cursor.position = end
        case .markdownFence:
            if cursor.trimmedStart(hasPrefix: Self.fence) { return ([CodeToken(0..<count, .punctuation)], .normal) }
            return ([CodeToken(0..<count, .string)], state)
        }

        let firstNonSpace = cursor.firstNonSpace
        if language.features.contains(.markdown), cursor.position == 0 {
            if let markdown = markdownLine(cursor, firstNonSpace: firstNonSpace) { return markdown }
        }
        if language.features.contains(.lineKeys), cursor.position == 0, firstNonSpace < count, units[firstNonSpace] == Ascii.openBracket,
           let close = units.lastIndex(of: Ascii.closeBracket), close > firstNonSpace {
            // `[раздел]` в TOML.
            tokens.append(CodeToken(firstNonSpace..<close + 1, .tag))
            cursor.position = close + 1
        }

        while cursor.position < count {
            let start = cursor.position
            let unit = units[start]
            if Ascii.isSpace(unit) {
                cursor.position += 1
                continue
            }
            if language.features.contains(.preprocessor), unit == Ascii.hash, start == firstNonSpace {
                cursor.position += 1
                cursor.skipIdentifier(extras: extras)
                tokens.append(CodeToken(start..<cursor.position, .annotation))
                continue
            }
            if let prefix = lineComments.first(where: { cursor.matches($0, at: start) }), !prefix.isEmpty {
                tokens.append(CodeToken(start..<count, .comment))
                return (tokens, .normal)
            }
            if let kind = blockComments.firstIndex(where: { cursor.matches($0.open, at: start) }) {
                let open = blockComments[kind].open.count
                guard let end = cursor.find(blockComments[kind].close, from: start + open) else {
                    tokens.append(CodeToken(start..<count, .comment))
                    return (tokens, .blockComment(kind))
                }
                tokens.append(CodeToken(start..<end, .comment))
                cursor.position = end
                continue
            }
            if language.features.contains(.markupTags), unit == Ascii.less, isTagStart(cursor, at: start) {
                scanTag(&cursor, into: &tokens)
                continue
            }
            if let kind = strings.firstIndex(where: { cursor.matches($0.open, at: start) }) {
                let rule = strings[kind]
                guard let end = cursor.findClose(rule.close, escape: rule.escape, from: start + rule.open.count) else {
                    tokens.append(CodeToken(start..<count, .string))
                    return (tokens, rule.multiline ? .string(kind) : .normal)
                }
                let isKey = language.features.contains(.quotedKeys) && cursor.nextNonSpace(from: end) == Ascii.colon
                tokens.append(CodeToken(start..<end, isKey ? .property : .string))
                cursor.position = end
                continue
            }
            if language.features.contains(.dollarVariables), unit == Ascii.dollar, start + 1 < count {
                let next = units[start + 1]
                if next == Ascii.openBrace, let close = units[(start + 1)...].firstIndex(of: Ascii.closeBrace) {
                    tokens.append(CodeToken(start..<close + 1, .variable))
                    cursor.position = close + 1
                    continue
                }
                if Ascii.isIdentifierStart(next) || Ascii.isDigit(next) {
                    cursor.position += 1
                    cursor.skipIdentifier(extras: [])
                    tokens.append(CodeToken(start..<cursor.position, .variable))
                    continue
                }
            }
            if language.features.contains(.atAnnotations), unit == Ascii.at, start + 1 < count, Ascii.isIdentifierStart(units[start + 1]) {
                cursor.position += 1
                cursor.skipIdentifier(extras: extras)
                tokens.append(CodeToken(start..<cursor.position, .annotation))
                continue
            }
            if Ascii.isDigit(unit) || (unit == Ascii.dot && start + 1 < count && Ascii.isDigit(units[start + 1])) {
                cursor.skipNumber()
                tokens.append(CodeToken(start..<cursor.position, .number))
                continue
            }
            if Ascii.isIdentifierStart(unit) {
                cursor.skipIdentifier(extras: extras)
                if let kind = wordKind(cursor, start: start, firstNonSpace: firstNonSpace) {
                    tokens.append(CodeToken(start..<cursor.position, kind))
                }
                continue
            }
            if Ascii.isPunctuation(unit) {
                let isOperator = Ascii.isOperator(unit)
                while cursor.position < count, Ascii.isPunctuation(units[cursor.position]),
                      Ascii.isOperator(units[cursor.position]) == isOperator,
                      cursor.position == start || !startsToken(units[cursor.position]),
                      !lineComments.contains(where: { cursor.matches($0, at: cursor.position) }),
                      !blockComments.contains(where: { cursor.matches($0.open, at: cursor.position) }),
                      !strings.contains(where: { cursor.matches($0.open, at: cursor.position) }) {
                    cursor.position += 1
                }
                if cursor.position == start { cursor.position += 1 }
                tokens.append(CodeToken(start..<cursor.position, isOperator ? .operator : .punctuation))
                continue
            }
            cursor.position += 1
        }
        return (tokens, .normal)
    }

    /// Знак сам начинает токен, и в общий кусок пунктуации его не склеить: `$` переменной, `@` пометки, `<` тега.
    private func startsToken(_ unit: UInt16) -> Bool {
        let features = language.features
        return unit == Ascii.dollar && features.contains(.dollarVariables) || unit == Ascii.at && features.contains(.atAnnotations)
            || unit == Ascii.less && features.contains(.markupTags)
    }

    // MARK: Слова

    private func wordKind(_ cursor: Cursor, start: Int, firstNonSpace: Int) -> CodeTokenKind? {
        let units = cursor.units
        let end = cursor.position
        var word = String(decoding: units[start..<end], as: UTF16.self)
        if language.caseInsensitive { word = word.lowercased() }
        let features = language.features
        if features.contains(.lineKeys), isLineKeyStart(units, start: start, firstNonSpace: firstNonSpace),
           let next = cursor.nextNonSpace(from: end), next == Ascii.colon || next == Ascii.equals {
            return .property
        }
        if features.contains(.cssProperties), cursor.nextNonSpace(from: end) == Ascii.colon,
           !units[end...].contains(Ascii.openBrace) {
            return .property
        }
        if language.keywords.contains(word) { return .keyword }
        if language.literals.contains(word) { return .literal }
        if language.types.contains(word) { return .type }
        if end < units.count, units[end] == Ascii.openParen { return .function }
        if features.contains(.capitalizedTypes), Ascii.isUppercase(units[start]) { return .type }
        return nil
    }

    /// Ключ YAML и TOML стоит первым в строке; у YAML — и после «- » пункта.
    private func isLineKeyStart(_ units: [UInt16], start: Int, firstNonSpace: Int) -> Bool {
        if start == firstNonSpace { return true }
        guard units[firstNonSpace] == Ascii.minus else { return false }
        var index = firstNonSpace + 1
        while index < start, Ascii.isSpace(units[index]) { index += 1 }
        return index == start
    }

    // MARK: Теги

    /// `<` открывает тег, а не сравнение: дальше буква, `/` или `!`; в JSX ещё и не после значения.
    private func isTagStart(_ cursor: Cursor, at index: Int) -> Bool {
        let units = cursor.units
        guard index + 1 < units.count else { return false }
        let next = units[index + 1]
        guard Ascii.isLetter(next) || next == Ascii.slash || next == Ascii.bang || next == Ascii.question || next == Ascii.greater
        else { return false }
        guard language.id == LanguageDefinition.jsx.id else { return true }
        var previous = index - 1
        while previous >= 0, Ascii.isSpace(units[previous]) { previous -= 1 }
        guard previous >= 0 else { return true }
        let before = units[previous]
        if Ascii.isIdentifierPart(before) {
            // После `return` и других ключевых слов — тег, после имени — сравнение.
            var wordStart = previous
            while wordStart > 0, Ascii.isIdentifierPart(units[wordStart - 1]) { wordStart -= 1 }
            return language.keywords.contains(String(decoding: units[wordStart...previous], as: UTF16.self))
        }
        return !(before == Ascii.closeParen || before == Ascii.closeBracket)
    }

    private func scanTag(_ cursor: inout Cursor, into tokens: inout [CodeToken]) {
        let units = cursor.units
        let count = units.count
        let start = cursor.position
        cursor.position += 1
        while cursor.position < count, units[cursor.position] == Ascii.slash || units[cursor.position] == Ascii.bang
                || units[cursor.position] == Ascii.question {
            cursor.position += 1
        }
        tokens.append(CodeToken(start..<cursor.position, .punctuation))
        let nameStart = cursor.position
        cursor.skipIdentifier(extras: [Ascii.minus, Ascii.colon, Ascii.dot])
        if cursor.position > nameStart { tokens.append(CodeToken(nameStart..<cursor.position, .tag)) }
        while cursor.position < count {
            let index = cursor.position
            let unit = units[index]
            if unit == Ascii.greater || (unit == Ascii.slash && index + 1 < count && units[index + 1] == Ascii.greater) {
                let end = unit == Ascii.greater ? index + 1 : index + 2
                tokens.append(CodeToken(index..<end, .punctuation))
                cursor.position = end
                return
            }
            if unit == Ascii.quote || unit == Ascii.apostrophe {
                let close = units[(index + 1)...].firstIndex(of: unit).map { $0 + 1 } ?? count
                tokens.append(CodeToken(index..<close, .string))
                cursor.position = close
                continue
            }
            if unit == Ascii.openBrace, let close = units[index...].firstIndex(of: Ascii.closeBrace) {
                // `{выражение}` в JSX — пунктуацией, содержимое не разбираем.
                tokens.append(CodeToken(index..<close + 1, .punctuation))
                cursor.position = close + 1
                continue
            }
            if Ascii.isIdentifierStart(unit) {
                cursor.skipIdentifier(extras: [Ascii.minus, Ascii.colon])
                tokens.append(CodeToken(index..<cursor.position, .attribute))
                continue
            }
            if unit == Ascii.equals { tokens.append(CodeToken(index..<index + 1, .punctuation)) }
            cursor.position += 1
        }
    }

    // MARK: Markdown

    private static let fence = Array("```".utf16)

    private func markdownLine(_ cursor: Cursor, firstNonSpace: Int) -> (tokens: [CodeToken], end: LineState)? {
        let units = cursor.units
        let count = units.count
        guard firstNonSpace < count else { return nil }
        if cursor.trimmedStart(hasPrefix: Self.fence) { return ([CodeToken(0..<count, .punctuation)], .markdownFence) }
        if units[firstNonSpace] == Ascii.hash {
            var index = firstNonSpace
            while index < count, units[index] == Ascii.hash { index += 1 }
            if index - firstNonSpace <= 6, index == count || Ascii.isSpace(units[index]) {
                return ([CodeToken(firstNonSpace..<count, .tag)], .normal)
            }
        }
        var tokens: [CodeToken] = []
        let marker = units[firstNonSpace]
        if (marker == Ascii.minus || marker == Ascii.star || marker == Ascii.plus || marker == Ascii.greater),
           firstNonSpace + 1 < count, Ascii.isSpace(units[firstNonSpace + 1]) {
            tokens.append(CodeToken(firstNonSpace..<firstNonSpace + 1, .punctuation))
        }
        // Код в строке `…`.
        var index = firstNonSpace
        while index < count {
            if units[index] == Ascii.backtick, let close = units[(index + 1)...].firstIndex(of: Ascii.backtick) {
                tokens.append(CodeToken(index..<close + 1, .string))
                index = close + 1
            } else {
                index += 1
            }
        }
        return (tokens, .normal)
    }
}

/// Место разбора в строке.
private struct Cursor {
    let units: [UInt16]
    var position = 0

    init(units: [UInt16]) {
        self.units = units
    }

    var firstNonSpace: Int {
        var index = 0
        while index < units.count, Ascii.isSpace(units[index]) { index += 1 }
        return index
    }

    func trimmedStart(hasPrefix prefix: [UInt16]) -> Bool {
        matches(prefix, at: firstNonSpace)
    }

    func matches(_ pattern: [UInt16], at index: Int) -> Bool {
        guard !pattern.isEmpty, index + pattern.count <= units.count else { return false }
        for offset in pattern.indices where units[index + offset] != pattern[offset] { return false }
        return true
    }

    /// Конец `pattern` (место после него), начиная с `from`.
    func find(_ pattern: [UInt16], from: Int) -> Int? {
        var index = from
        while index + pattern.count <= units.count {
            if matches(pattern, at: index) { return index + pattern.count }
            index += 1
        }
        return nil
    }

    /// Конец закрывающих знаков строки с учётом экранирования.
    func findClose(_ close: [UInt16], escape: UInt16?, from: Int) -> Int? {
        var index = from
        while index < units.count {
            if let escape, units[index] == escape {
                index += 2
                continue
            }
            if matches(close, at: index) { return index + close.count }
            index += 1
        }
        return nil
    }

    func nextNonSpace(from index: Int) -> UInt16? {
        var index = index
        while index < units.count, Ascii.isSpace(units[index]) { index += 1 }
        return index < units.count ? units[index] : nil
    }

    mutating func skipIdentifier(extras: Set<UInt16>) {
        while position < units.count, Ascii.isIdentifierPart(units[position]) || extras.contains(units[position]) {
            position += 1
        }
    }

    /// Число: `42`, `3.14`, `0xFF`, `1_000`, `1e-9`.
    mutating func skipNumber() {
        while position < units.count {
            let unit = units[position]
            if Ascii.isIdentifierPart(unit) || unit == Ascii.dot && position + 1 < units.count && Ascii.isDigit(units[position + 1]) {
                let isExponent = unit == Ascii.lowerE || unit == Ascii.upperE
                position += 1
                if isExponent, position < units.count, units[position] == Ascii.minus || units[position] == Ascii.plus { position += 1 }
            } else {
                return
            }
        }
    }
}

/// Классы знаков в UTF-16. Знаки вне ASCII (кириллица в именах) — буквы.
enum Ascii {
    static let hash: UInt16 = 0x23, dollar: UInt16 = 0x24, at: UInt16 = 0x40, dot: UInt16 = 0x2E, colon: UInt16 = 0x3A
    static let equals: UInt16 = 0x3D, less: UInt16 = 0x3C, greater: UInt16 = 0x3E, slash: UInt16 = 0x2F, bang: UInt16 = 0x21
    static let question: UInt16 = 0x3F, quote: UInt16 = 0x22, apostrophe: UInt16 = 0x27, backtick: UInt16 = 0x60
    static let openBrace: UInt16 = 0x7B, closeBrace: UInt16 = 0x7D, openParen: UInt16 = 0x28, closeParen: UInt16 = 0x29
    static let openBracket: UInt16 = 0x5B, closeBracket: UInt16 = 0x5D, minus: UInt16 = 0x2D, plus: UInt16 = 0x2B, star: UInt16 = 0x2A
    static let lowerE: UInt16 = 0x65, upperE: UInt16 = 0x45, underscore: UInt16 = 0x5F

    static func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0xA0 }
    static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }
    static func isUppercase(_ unit: UInt16) -> Bool { unit >= 0x41 && unit <= 0x5A }
    static func isLetter(_ unit: UInt16) -> Bool { (unit | 0x20) >= 0x61 && (unit | 0x20) <= 0x7A || unit >= 0x80 && !isSpace(unit) }
    static func isIdentifierStart(_ unit: UInt16) -> Bool { isLetter(unit) || unit == underscore }
    static func isIdentifierPart(_ unit: UInt16) -> Bool { isIdentifierStart(unit) || isDigit(unit) }
    /// `+ - * / = < > ! & | ^ % ~ ? :`.
    static func isOperator(_ unit: UInt16) -> Bool {
        [0x2B, 0x2D, 0x2A, 0x2F, 0x3D, 0x3C, 0x3E, 0x21, 0x26, 0x7C, 0x5E, 0x25, 0x7E, 0x3F, 0x3A].contains(unit)
    }

    static func isPunctuation(_ unit: UInt16) -> Bool {
        unit < 0x80 && !isIdentifierPart(unit) && !isSpace(unit) && unit > 0x20 && unit != quote && unit != apostrophe && unit != backtick
    }
}
