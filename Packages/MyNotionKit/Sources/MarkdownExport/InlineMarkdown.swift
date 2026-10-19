import Foundation
import NotesCore

/// Текст блока с оформлением в строке — в Markdown. Перенос строки остаётся символом `\n`: блок превращает его
/// в «два пробела и отступ». Смещения оформления — в единицах UTF-16, как в `InlineText`.
enum InlineMarkdown {
    static func render(_ text: InlineText) -> String {
        let units = Array(text.string.utf16)
        guard !units.isEmpty else { return "" }
        // Наложение и выход за край текста разбирают сами отрезки: полная нормализация на каждый блок только тормозит.
        let segments = segments(of: text, unitCount: units.count)
        var plan = Plan(units: units)
        for (index, segment) in segments.enumerated() { plan.add(segment, at: index, in: segments) }
        return plan.rendered()
    }

    // MARK: Отрезки

    private struct Marks: OptionSet {
        let rawValue: Int
        static let bold = Marks(rawValue: 1)
        static let italic = Marks(rawValue: 2)
        static let strikethrough = Marks(rawValue: 4)
        static let underline = Marks(rawValue: 8)
        static let code = Marks(rawValue: 16)
    }

    private struct Segment {
        var range: Range<Int>
        var marks: Marks
        var link: URL?
    }

    /// Текст, разрезанный по всем границам оформления; соседние куски с одним видом слиты.
    private static func segments(of text: InlineText, unitCount: Int) -> [Segment] {
        var boundaries: Set<Int> = [0, unitCount]
        for run in text.runs {
            boundaries.insert(min(max(run.start, 0), unitCount))
            boundaries.insert(min(max(run.start + run.length, 0), unitCount))
        }
        let sorted = boundaries.sorted()
        var result: [Segment] = []
        for (lower, upper) in zip(sorted, sorted.dropFirst()) {
            var segment = Segment(range: lower..<upper, marks: [], link: nil)
            for run in text.runs where run.start <= lower && run.start + run.length >= upper {
                switch run.style {
                case .bold: segment.marks.insert(.bold)
                case .italic: segment.marks.insert(.italic)
                case .strikethrough: segment.marks.insert(.strikethrough)
                case .underline: segment.marks.insert(.underline)
                case .code: segment.marks.insert(.code)
                case .link(let url): segment.link = url
                // Цвета, упоминания, даты и формулы в Markdown пишут свои этапы (contracts/markdown-and-notion.md).
                case .textColor, .backgroundColor, .mention, .date, .equation: break
                }
            }
            if var last = result.last, last.marks == segment.marks, last.link == segment.link {
                last.range = last.range.lowerBound..<upper
                result[result.count - 1] = last
            } else {
                result.append(segment)
            }
        }
        return result
    }

    // MARK: Сборка

    private enum Delimiter: Equatable {
        case link(URL)
        case bold, italic, strikethrough, underline

        func contains(in segment: Segment) -> Bool {
            switch self {
            case .link(let url): segment.link == url
            case .bold: segment.marks.contains(.bold)
            case .italic: segment.marks.contains(.italic)
            case .strikethrough: segment.marks.contains(.strikethrough)
            case .underline: segment.marks.contains(.underline)
            }
        }
    }

    /// Один открытый и закрытый знак оформления. Знаки `**`, `*`, `~~` читалка принимает не везде (рядом с буквой,
    /// скобкой, другим таким же знаком), тогда оформление пишется тегом: `<strong>`, `<em>`, `<del>`.
    private struct Span {
        let delimiter: Delimiter
        var usesTag = false

        var opening: String {
            switch delimiter {
            case .link: "["
            case .bold: usesTag ? "<strong>" : "**"
            case .italic: usesTag ? "<em>" : "*"
            case .strikethrough: usesTag ? "<del>" : "~~"
            case .underline: "<u>"
            }
        }

        var closing: String {
            switch delimiter {
            case .link(let url): "](\(InlineMarkdown.encodedDestination(url)))"
            case .bold: usesTag ? "</strong>" : "**"
            case .italic: usesTag ? "</em>" : "*"
            case .strikethrough: usesTag ? "</del>" : "~~"
            case .underline: "</u>"
            }
        }

        /// Знак, из которого состоит запись: подряд идущие одинаковые читалка сливает в одну серию.
        var markCharacter: Character? {
            guard !usesTag else { return nil }
            switch delimiter {
            case .bold, .italic: return "*"
            case .strikethrough: return "~"
            case .link, .underline: return nil
            }
        }
    }

    private enum Item {
        case text(String)
        case space(String)
        case open(Int)
        case close(Int)
    }

    /// Сначала план: где открываются и закрываются знаки (стопкой: закрывается то, что открыто позже), потом проверка
    /// каждого стыка по правилам читалки, потом запись. Пробелы на краю отрезка стоят снаружи знаков
    /// (`**жирный** текст`, а не `**жирный **текст`): иначе Markdown не распознает оформление.
    private struct Plan {
        let units: [UInt16]
        private var items: [Item] = []
        private var spans: [Span] = []
        private var open: [Int] = []
        private var pendingSpace = ""

        init(units: [UInt16]) { self.units = units }

        mutating func add(_ segment: Segment, at index: Int, in segments: [Segment]) {
            var start = segment.range.lowerBound
            var end = segment.range.upperBound
            while start < end, InlineMarkdown.isSpace(units[start]) { start += 1 }
            while end > start, InlineMarkdown.isSpace(units[end - 1]) { end -= 1 }
            pendingSpace += String(decoding: units[segment.range.lowerBound..<start], as: UTF16.self)
            guard start < end else { return }

            transition(to: desiredDelimiters(at: index, in: segments))
            if segment.marks.contains(.code) {
                items.append(.text(InlineMarkdown.codeSpan(String(decoding: units[start..<end], as: UTF16.self))))
            } else {
                items.append(.text(InlineMarkdown.escape(units, range: start..<end)))
            }
            pendingSpace = String(decoding: units[end..<segment.range.upperBound], as: UTF16.self)
        }

        /// Нужные отрезку знаки. Что охватывает больше отрезков подряд — снаружи: так меньше закрытий и повторных открытий.
        private func desiredDelimiters(at index: Int, in segments: [Segment]) -> [Delimiter] {
            let segment = segments[index]
            var candidates: [Delimiter] = []
            if let link = segment.link { candidates.append(.link(link)) }
            for (delimiter, isMarked) in [(Delimiter.bold, Marks.bold), (.italic, .italic), (.strikethrough, .strikethrough),
                                          (.underline, .underline)] where segment.marks.contains(isMarked) {
                candidates.append(delimiter)
            }
            func reach(_ delimiter: Delimiter) -> Int {
                segments[index...].prefix { delimiter.contains(in: $0) }.count
            }
            let reaches = candidates.map(reach)
            return candidates.indices.sorted { reaches[$0] != reaches[$1] ? reaches[$0] > reaches[$1] : $0 < $1 }.map { candidates[$0] }
        }

        /// Закрыть всё, что дальше не нужно (вместе с открытым после него — оно откроется заново), затем пробелы и новое.
        private mutating func transition(to desired: [Delimiter]) {
            let firstUnwanted = open.firstIndex { !desired.contains(spans[$0].delimiter) } ?? open.count
            for id in open[firstUnwanted...].reversed() { items.append(.close(id)) }
            open.removeSubrange(firstUnwanted...)
            if !pendingSpace.isEmpty {
                items.append(.space(pendingSpace))
                pendingSpace = ""
            }
            for delimiter in desired where !open.contains(where: { spans[$0].delimiter == delimiter }) {
                spans.append(Span(delimiter: delimiter))
                open.append(spans.count - 1)
                items.append(.open(spans.count - 1))
            }
        }

        mutating func rendered() -> String {
            transition(to: [])
            resolveTags()
            var output = ""
            for item in items {
                // «!» прямо перед «[» читалка складывает в картинку.
                if case .open(let id) = item, case .link = spans[id].delimiter, output.last == "!" {
                    output.removeLast()
                    output += "\\!"
                }
                output += text(of: item)
            }
            return output
        }

        private func text(of item: Item) -> String {
            switch item {
            case .text(let string), .space(let string): string
            case .open(let id): spans[id].opening
            case .close(let id): spans[id].closing
            }
        }

        // MARK: Стыки

        /// Между двумя кусками текста стоят закрывающие знаки, пробелы и открывающие. Читалка принимает серию звёздочек
        /// или тильд как оформление, только если она «прилегает» к тексту с нужной стороны (правила CommonMark про
        /// пробелы и знаки препинания). Что не прошло — пишется тегом. Теги убирают серии, поэтому проверка идёт, пока
        /// есть что менять.
        private mutating func resolveTags() {
            var changed = true
            while changed {
                changed = false
                let textIndices = items.indices.filter { if case .text = items[$0] { true } else { false } }
                for position in 0...textIndices.count {
                    let lower = position == 0 ? 0 : textIndices[position - 1] + 1
                    let upper = position == textIndices.count ? items.count : textIndices[position]
                    guard lower < upper else { continue }
                    let before = position == 0 ? nil : lastCharacter(of: items[textIndices[position - 1]])
                    let after = position == textIndices.count ? nil : firstCharacter(of: items[textIndices[position]])
                    for id in spansNeedingTags(in: lower..<upper, before: before, after: after) where !spans[id].usesTag {
                        spans[id].usesTag = true
                        changed = true
                    }
                }
            }
        }

        private func firstCharacter(of item: Item) -> Character? { text(of: item).first }
        private func lastCharacter(of item: Item) -> Character? { text(of: item).last }

        private func spansNeedingTags(in range: Range<Int>, before: Character?, after: Character?) -> [Int] {
            let junction = Array(items[range])
            var result: [Int] = []
            var start = 0
            while start < junction.count {
                guard let mark = markCharacter(of: junction[start]) else { start += 1; continue }
                var end = start
                while end < junction.count, markCharacter(of: junction[end]) == mark { end += 1 }
                let run = junction[start..<end]
                let characterBefore = start == 0 ? before : text(of: junction[start - 1]).last
                let characterAfter = end == junction.count ? after : text(of: junction[end]).first
                let openers = run.compactMap { if case .open(let id) = $0 { id } else { nil } }
                let closers = run.compactMap { if case .close(let id) = $0 { id } else { nil } }
                if InlineMarkdown.isBetweenPunctuation(before: characterBefore, after: characterAfter) {
                    // Серия между знаками препинания и открывает, и закрывает; как читалка её сопоставит, зависит от длин соседних серий.
                    result += openers + closers
                } else if !openers.isEmpty, !closers.isEmpty {
                    // «**а**» и сразу «*б*»: серия из пяти звёздочек — не разобрать, где что закрывается.
                    result += openers
                } else if !openers.isEmpty, !InlineMarkdown.isLeftFlanking(before: characterBefore, after: characterAfter) {
                    result += openers
                } else if !closers.isEmpty, !InlineMarkdown.isRightFlanking(before: characterBefore, after: characterAfter) {
                    result += closers
                }
                start = end
            }
            return result
        }

        private func markCharacter(of item: Item) -> Character? {
            switch item {
            case .open(let id), .close(let id): spans[id].markCharacter
            case .text, .space: nil
            }
        }
    }

    // MARK: Прилегание знаков (CommonMark, «flanking»)

    private enum CharacterClass { case whitespace, punctuation, other }

    private static func characterClass(_ character: Character?) -> CharacterClass {
        guard let character else { return .whitespace }
        if character.isWhitespace { return .whitespace }
        if character.isPunctuation || character.isSymbol { return .punctuation }
        return .other
    }

    fileprivate static func isBetweenPunctuation(before: Character?, after: Character?) -> Bool {
        characterClass(before) == .punctuation && characterClass(after) == .punctuation
    }

    /// Серия может открыть оформление: за ней не пробел, а знак препинания за ней допустим, только если перед серией пробел или знак.
    fileprivate static func isLeftFlanking(before: Character?, after: Character?) -> Bool {
        let next = characterClass(after)
        return next != .whitespace && (next != .punctuation || characterClass(before) != .other)
    }

    /// Серия может закрыть оформление: перед ней не пробел, а знак препинания перед ней допустим, только если за серией пробел или знак.
    fileprivate static func isRightFlanking(before: Character?, after: Character?) -> Bool {
        let previous = characterClass(before)
        return previous != .whitespace && (previous != .punctuation || characterClass(after) != .other)
    }

    // MARK: Код, адреса, экранирование

    /// Пробел, табуляция, перенос, неразрывный и прочие пробелы Юникода: читалка считает их пробелами у знаков оформления.
    fileprivate static func isSpace(_ unit: UInt16) -> Bool {
        if unit < 0x80 { return unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D }
        return Unicode.Scalar(unit)?.properties.isWhitespace ?? false
    }

    /// Код в обратных кавычках: рамка длиннее самой длинной серии кавычек внутри, внутри ничего не экранируется.
    static func codeSpan(_ code: String) -> String {
        var longest = 0
        var current = 0
        for character in code {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let padding = code.hasPrefix("`") || code.hasSuffix("`") ? " " : ""
        return fence + padding + code + padding + fence
    }

    private static let unsafeInAddress: [Character: String] = [" ": "%20", "(": "%28", ")": "%29", "<": "%3C", ">": "%3E"]

    static func encodedDestination(_ url: URL) -> String {
        url.absoluteString.map { unsafeInAddress[$0] ?? String($0) }.joined()
    }

    private static let unsafeInPath: Set<Unicode.Scalar> = Set(" ()%#?<>[]\\`\"|^{}".unicodeScalars)

    /// Путь файла в ссылке: кириллица остаётся, пробелы, скобки и знаки адреса кодируются.
    static func encodedPath(_ path: String) -> String {
        var result = ""
        for scalar in path.unicodeScalars {
            if unsafeInPath.contains(scalar) {
                for byte in String(scalar).utf8 { result += String(format: "%%%02X", byte) }
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Обычный текст так, чтобы Markdown не принял его за оформление. Начало строки и соседние символы
    /// смотрятся в целом тексте `units`, а не только в `range`.
    static func escape(_ units: [UInt16], range: Range<Int>) -> String {
        // Обычный текст без служебных знаков (почти всё) отдаётся целиком.
        if !range.contains(where: { isMarkdownSignificant(units[$0]) }) {
            return String(decoding: units[range], as: UTF16.self)
        }
        var result: [UInt16] = []
        result.reserveCapacity(range.count + 4)
        for index in range {
            if needsEscape(units, at: index) { result.append(0x5C) }
            result.append(units[index])
        }
        return String(decoding: result, as: UTF16.self)
    }

    /// Знаки, перед которыми `needsEscape` может поставить обратную косую черту.
    private static func isMarkdownSignificant(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x5C, 0x60, 0x2A, 0x5B, 0x5D, 0x3C, 0x7E, 0x5F, 0x26, 0x23, 0x3E, 0x2D, 0x2B, 0x3D, 0x2E, 0x29: true
        default: false
        }
    }

    private static func needsEscape(_ units: [UInt16], at index: Int) -> Bool {
        let unit = units[index]
        let previous: UInt16? = index > 0 ? units[index - 1] : nil
        let next: UInt16? = index + 1 < units.count ? units[index + 1] : nil
        let startsLine = previous == nil || previous == 0x0A
        let nextEndsToken = next == nil || next == 0x20 || next == 0x0A

        switch unit {
        case 0x5C, 0x60, 0x2A, 0x5B, 0x5D, 0x3C, 0x7E: // \ ` * [ ] < ~
            return true
        case 0x5F: // _ : внутри слова оформления не начинает
            return !(isLetterOrDigit(previous) && isLetterOrDigit(next))
        case 0x26: // & : начало «&copy;»
            return next == 0x23 || isLetterOrDigit(next)
        case 0x23, 0x3E: // # >
            return startsLine
        case 0x2D, 0x2B, 0x3D: // - + =
            return startsLine && (nextEndsToken || next == unit)
        case 0x2E, 0x29: // . ) после номера в начале строки
            guard nextEndsToken else { return false }
            var cursor = index - 1
            var digits = 0
            while cursor >= 0, units[cursor] >= 0x30, units[cursor] <= 0x39 {
                digits += 1
                cursor -= 1
            }
            return (1...9).contains(digits) && (cursor < 0 || units[cursor] == 0x0A)
        default:
            return false
        }
    }

    private static func isLetterOrDigit(_ unit: UInt16?) -> Bool {
        guard let unit, let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}
