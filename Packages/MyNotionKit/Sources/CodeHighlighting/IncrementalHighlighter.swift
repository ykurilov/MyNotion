import Foundation

/// Разобранная строка кода: токены от её начала и состояние на её конце.
public struct HighlightedLine: Sendable, Hashable {
    public var tokens: [CodeToken]
    public var end: LineState
}

/// Подсветка блока кода по строкам (research R5). На конце каждой строки хранится состояние; правка перекрашивает
/// строки правки и следующие, пока состояние конца строки не совпало с прежним — обычно одну строку.
public struct IncrementalHighlighter: Sendable {
    public let scanner: LineScanner
    /// Начала строк в единицах UTF-16; строки разделены `\n`.
    public private(set) var lineStarts: [Int] = [0]
    public private(set) var lines: [HighlightedLine] = []
    /// Длина текста в единицах UTF-16.
    public private(set) var length = 0

    public var language: LanguageDefinition { scanner.language }

    /// Полный разбор текста.
    public init(language: LanguageDefinition, text: String) {
        scanner = LineScanner(language: language)
        let units = Array(text.utf16)
        lineStarts = Self.lineStarts(of: units)
        length = units.count
        var state = LineState.normal
        lines.reserveCapacity(lineStarts.count)
        for index in lineStarts.indices {
            let line = scanner.scan(Array(units[lineRange(index, in: units.count)]), from: state)
            lines.append(HighlightedLine(tokens: line.tokens, end: line.end))
            state = line.end
        }
    }

    /// Правка текста: в новом тексте `text` изменён отрезок `editedRange`, длина выросла на `changeInLength`
    /// (как у `NSTextStorage`). Возвращает строки (номера в новом тексте), чьи токены разобраны заново.
    @discardableResult
    public mutating func apply(text: String, editedRange: NSRange, changeInLength: Int) -> Range<Int> {
        let units = Array(text.utf16)
        let newStarts = Self.lineStarts(of: units)
        let oldStarts = lineStarts
        let firstLine = Self.line(containing: editedRange.location, in: newStarts)
        let lastNewLine = Self.line(containing: NSMaxRange(editedRange), in: newStarts)
        let lastOldLine = Self.line(containing: NSMaxRange(editedRange) - changeInLength, in: oldStarts)
        let lineDelta = (lastNewLine - firstLine) - (lastOldLine - firstLine)

        lineStarts = newStarts
        length = units.count
        var updated = Array(lines[..<min(firstLine, lines.count)])
        updated.reserveCapacity(newStarts.count)
        var state = firstLine > 0 ? lines[firstLine - 1].end : .normal
        var index = firstLine
        while index < newStarts.count {
            let line = scanner.scan(Array(units[lineRange(index, in: units.count)]), from: state)
            updated.append(HighlightedLine(tokens: line.tokens, end: line.end))
            state = line.end
            let oldIndex = index - lineDelta
            if index >= lastNewLine, oldIndex >= 0, oldIndex < lines.count, lines[oldIndex].end == line.end {
                // Дальше всё как было: строки только сдвинулись.
                updated += lines[(oldIndex + 1)...]
                break
            }
            index += 1
        }
        lines = updated
        return firstLine..<min(index + 1, newStarts.count)
    }

    /// Отрезок строки `index` в тексте, без её `\n`.
    public func lineRange(_ index: Int) -> Range<Int> {
        lineRange(index, in: length)
    }

    private func lineRange(_ index: Int, in length: Int) -> Range<Int> {
        let start = lineStarts[index]
        let end = index + 1 < lineStarts.count ? lineStarts[index + 1] - 1 : length
        return start..<max(start, end)
    }

    /// Токены строк `range` в координатах всего текста.
    public func tokens(inLines range: Range<Int>) -> [CodeToken] {
        range.flatMap { index in
            let start = lineStarts[index]
            return lines[index].tokens.map { CodeToken(($0.range.lowerBound + start)..<($0.range.upperBound + start), $0.kind) }
        }
    }

    static func lineStarts(of units: [UInt16]) -> [Int] {
        var starts = [0]
        for (index, unit) in units.enumerated() where unit == 0x0A { starts.append(index + 1) }
        return starts
    }

    /// Строка, в которой стоит место `location`; место сразу после `\n` — уже следующая строка.
    static func line(containing location: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= location { low = middle } else { high = middle - 1 }
        }
        return low
    }
}
