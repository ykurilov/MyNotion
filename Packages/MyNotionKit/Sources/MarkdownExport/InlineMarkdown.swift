import Foundation
import NotesCore

/// Текст блока с оформлением в строке — в Markdown. Перенос строки остаётся символом `\n`: блок превращает его
/// в «два пробела и отступ». Смещения оформления — в единицах UTF-16, как в `InlineText`.
enum InlineMarkdown {
    static func render(_ text: InlineText) -> String {
        let units = Array(text.string.utf16)
        guard !units.isEmpty else { return "" }
        // Наложение и выход за край текста разбирают сами отрезки: полная нормализация на каждый блок только тормозит.
        var builder = Builder(units: units)
        for segment in segments(of: text, unitCount: units.count) { builder.add(segment) }
        return builder.finish()
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

        var opening: String {
            switch self {
            case .link: "["
            case .bold: "**"
            case .italic: "*"
            case .strikethrough: "~~"
            case .underline: "<u>"
            }
        }

        var closing: String {
            switch self {
            case .link(let url): "](\(InlineMarkdown.encodedDestination(url)))"
            case .bold: "**"
            case .italic: "*"
            case .strikethrough: "~~"
            case .underline: "</u>"
            }
        }
    }

    /// Открытые знаки оформления идут стопкой. Пробелы на краю отрезка стоят снаружи знаков
    /// (`**жирный** текст`, а не `**жирный **текст`): иначе Markdown не распознает оформление.
    private struct Builder {
        let units: [UInt16]
        var output = ""
        var pendingSpace = ""
        var open: [Delimiter] = []

        init(units: [UInt16]) { self.units = units }

        mutating func add(_ segment: Segment) {
            var start = segment.range.lowerBound
            var end = segment.range.upperBound
            while start < end, InlineMarkdown.isSpace(units[start]) { start += 1 }
            while end > start, InlineMarkdown.isSpace(units[end - 1]) { end -= 1 }
            pendingSpace += String(decoding: units[segment.range.lowerBound..<start], as: UTF16.self)
            guard start < end else { return }

            transition(to: desiredDelimiters(for: segment))
            if segment.marks.contains(.code) {
                output += InlineMarkdown.codeSpan(String(decoding: units[start..<end], as: UTF16.self))
            } else {
                output += InlineMarkdown.escape(units, range: start..<end)
            }
            pendingSpace = String(decoding: units[end..<segment.range.upperBound], as: UTF16.self)
        }

        mutating func finish() -> String {
            transition(to: [])
            return output + pendingSpace
        }

        private func desiredDelimiters(for segment: Segment) -> [Delimiter] {
            var desired: [Delimiter] = []
            if let link = segment.link { desired.append(.link(link)) }
            if segment.marks.contains(.bold) { desired.append(.bold) }
            if segment.marks.contains(.italic) { desired.append(.italic) }
            if segment.marks.contains(.strikethrough) { desired.append(.strikethrough) }
            if segment.marks.contains(.underline) { desired.append(.underline) }
            return desired
        }

        /// Закрыть всё, что дальше не нужно (вместе с открытым после него — оно откроется заново), пробелы, затем открыть новое.
        private mutating func transition(to desired: [Delimiter]) {
            let firstUnwanted = open.firstIndex { !desired.contains($0) } ?? open.count
            var closers = ""
            for delimiter in open[firstUnwanted...].reversed() { closers += delimiter.closing }
            open.removeSubrange(firstUnwanted...)
            var openers = ""
            for delimiter in desired where !open.contains(delimiter) {
                openers += delimiter.opening
                open.append(delimiter)
            }
            output += closers + pendingSpace + openers
            pendingSpace = ""
        }
    }

    // MARK: Код, адреса, экранирование

    fileprivate static func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A }

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
