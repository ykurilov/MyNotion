import Foundation
import NotesCore

/// Выделенный текст для проверки и обратно: куски блоков (`InlineText`) → одна строка для модели → исправленные куски
/// с тем же оформлением.
///
/// Модель видит простой текст: оформление (жирный, ссылки, цвета) остаётся у нас и переносится по сравнению букв
/// «было → стало». Что модель трогать не должна — упоминания, даты, формулы и код в строке — уходит метками `⟦1⟧`,
/// куски блоков разделены пустой строкой. Метки и переводы строк обязаны вернуться на месте, иначе — `formattingLost`.
public struct ProofreadText: Sendable {
    /// Неизменяемая вставка: кусок исходного текста (с его оформлением) под меткой.
    struct Token: Sendable {
        let segment: Int
        /// Где в куске блока, UTF-16.
        let range: Range<Int>
        /// Где метка в строке для модели.
        let placeholder: Range<Int>
        let original: InlineText
    }

    /// Чем был знак строки для модели.
    enum Origin: Sendable {
        /// Буква куска `segment` на месте `offset`.
        case text(segment: Int, offset: Int)
        case token(Int)
        case separator
    }

    public let segments: [InlineText]
    /// Строка для модели.
    public let source: String
    let units: [unichar]
    let origins: [Origin]
    /// Знаки, которые должны вернуться без изменений: метки, переводы строк, разделители.
    let protected: [Bool]
    let tokens: [Token]
    /// Где куски в строке для модели.
    let segmentRanges: [Range<Int>]

    static let separator = Array("\n\n".utf16)
    static let openMark: unichar = 0x27E6, closeMark: unichar = 0x27E7, newline: unichar = 0x0A

    public init(segments: [InlineText]) {
        self.segments = segments
        var units: [unichar] = [], origins: [Origin] = [], protected: [Bool] = [], tokens: [Token] = [], ranges: [Range<Int>] = []
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                units += Self.separator
                origins += Self.separator.map { _ in .separator }
                protected += Self.separator.map { _ in true }
            }
            let start = units.count
            let text = Array(segment.string.utf16)
            let spans = Self.protectedSpans(of: segment, length: text.count)
            var offset = 0
            for span in spans + [text.count..<text.count] {
                while offset < span.lowerBound {
                    let unit = text[offset]
                    units.append(unit)
                    origins.append(.text(segment: index, offset: offset))
                    protected.append(unit == Self.newline || unit == Self.openMark || unit == Self.closeMark)
                    offset += 1
                }
                guard !span.isEmpty else { break }
                let mark = Array("⟦\(tokens.count + 1)⟧".utf16)
                let placeholder = units.count..<units.count + mark.count
                tokens.append(Token(segment: index, range: span, placeholder: placeholder, original: segment.slice(span)))
                units += mark
                origins += mark.map { _ in .token(tokens.count - 1) }
                protected += mark.map { _ in true }
                offset = span.upperBound
            }
            ranges.append(start..<units.count)
        }
        self.units = units
        self.origins = origins
        self.protected = protected
        self.tokens = tokens
        segmentRanges = ranges
        source = String(decoding: units, as: UTF16.self)
    }

    /// Упоминания, даты, формулы и код в строке — слитые отрезки по порядку.
    static func protectedSpans(of text: InlineText, length: Int) -> [Range<Int>] {
        var covered = IndexSet()
        for run in text.runs where run.style.isAtom || run.style == .code {
            let start = max(0, run.start), end = min(length, run.start + run.length)
            if start < end { covered.insert(integersIn: start..<end) }
        }
        return covered.rangeView.map { $0.lowerBound..<$0.upperBound }
    }

    // MARK: Обратно

    /// Исправленный текст модели с пробелами по краям, как в исходном: модель их часто срезает.
    func normalized(_ corrected: String) -> [unichar] {
        let leading = units.prefix { Self.isWhitespace($0) }
        let trailing = units.reversed().prefix { Self.isWhitespace($0) }.reversed()
        guard leading.count < units.count else { return units }
        var core = Array(corrected.utf16)
        while let first = core.first, Self.isWhitespace(first) { core.removeFirst() }
        while let last = core.last, Self.isWhitespace(last) { core.removeLast() }
        return Array(leading) + core + Array(trailing)
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == newline || unit == 0x0D || unit == 0xA0
    }

    /// Есть ли что исправлять.
    public func hasChanges(_ corrected: String) -> Bool {
        normalized(corrected) != units
    }

    /// Исправленные куски с прежним оформлением. Метка, перевод строки или разделитель потерялись — `formattingLost`.
    public func apply(_ corrected: String) throws -> [InlineText] {
        let target = normalized(corrected)
        let alignment = Alignment(source: units, target: target)
        try verify(alignment, target: target)

        let styles = segments.map(Self.unitStyles)
        func style(ofSource index: Int) -> Set<InlineStyle> {
            if case .text(let segment, let offset) = origins[index] { return styles[segment][offset] }
            return []
        }
        // Стиль каждого знака исправленного текста: совпавший — как был; вставленный внутри заменённого куска — как
        // заменённые знаки; вставленный между нетронутыми — общий стиль соседей (запятая после ссылки — не ссылка).
        var targetStyles = [Set<InlineStyle>](repeating: [], count: target.count)
        for (sourceIndex, targetIndex) in alignment.pairs { targetStyles[targetIndex] = style(ofSource: sourceIndex) }
        for hunk in alignment.hunks {
            for (position, targetIndex) in hunk.target.enumerated() {
                if hunk.source.isEmpty {
                    let before = hunk.source.lowerBound > 0 ? style(ofSource: hunk.source.lowerBound - 1) : []
                    let after = hunk.source.lowerBound < units.count ? style(ofSource: hunk.source.lowerBound) : []
                    targetStyles[targetIndex] = before.intersection(after)
                } else {
                    targetStyles[targetIndex] = style(ofSource: hunk.source.lowerBound + min(position, hunk.source.count - 1))
                }
            }
        }

        let map = alignment.sourceToTarget
        var tokenStarts: [Int: Int] = [:]
        for (index, token) in tokens.enumerated() { if let start = map[token.placeholder.lowerBound] { tokenStarts[start] = index } }
        return segmentRanges.enumerated().map { index, range in
            // Края куска — разделители, они на месте: кусок исправленного текста между ними.
            let start = index == 0 ? 0 : map[range.lowerBound - 1]! + 1
            let end = index == segmentRanges.count - 1 ? target.count : map[range.upperBound]!
            return build(target: target, range: start..<end, styles: targetStyles, tokenStarts: tokenStarts)
        }
    }

    private func verify(_ alignment: Alignment, target: [unichar]) throws {
        let map = alignment.sourceToTarget
        for index in units.indices where protected[index] && map[index] == nil { throw ProofreadingError.formattingLost }
        // Меток и переводов строк не прибавилось, а знаки каждой метки и разделителя стоят подряд.
        let marks: Set<unichar> = [Self.openMark, Self.closeMark, Self.newline]
        guard target.filter(marks.contains).count == units.filter(marks.contains).count else { throw ProofreadingError.formattingLost }
        var ranges = tokens.map(\.placeholder)
        for range in segmentRanges.dropFirst() { ranges.append(range.lowerBound - Self.separator.count..<range.lowerBound) }
        for range in ranges {
            guard let first = map[range.lowerBound], let last = map[range.upperBound - 1], last - first == range.count - 1 else {
                throw ProofreadingError.formattingLost
            }
        }
    }

    /// Кусок исправленного текста: буквы со своим оформлением, метки — исходными вставками (`tokenStarts`: место → номер).
    private func build(target: [unichar], range: Range<Int>, styles: [Set<InlineStyle>], tokenStarts map: [Int: Int]) -> InlineText {
        var output: [unichar] = [], runs: [StyledRun] = []
        var index = range.lowerBound
        while index < range.upperBound {
            if let token = map[index] {
                let original = tokens[token].original
                let base = output.count
                output += Array(original.string.utf16)
                runs += original.runs.map { StyledRun(start: $0.start + base, length: $0.length, style: $0.style) }
                index += tokens[token].placeholder.count
                continue
            }
            for style in styles[index] { runs.append(StyledRun(start: output.count, length: 1, style: style)) }
            output.append(target[index])
            index += 1
        }
        return InlineText(String(decoding: output, as: UTF16.self), runs: runs).normalized()
    }

    /// Оформление каждого знака куска, кроме вставок (у них своё).
    static func unitStyles(of text: InlineText) -> [Set<InlineStyle>] {
        let length = text.string.utf16.count
        var styles = [Set<InlineStyle>](repeating: [], count: length)
        for run in text.runs where !run.style.isAtom {
            for index in max(0, run.start)..<min(length, run.start + run.length) { styles[index].insert(run.style) }
        }
        return styles
    }

    // MARK: Для окна правок

    /// Строка для показа: метки — видимым текстом вставок (`visible`), граница блоков — одним переводом строки.
    /// Пустая строка внутри блока (два ⇧Enter) остаётся.
    public func displayText(of text: String, visible: (InlineText) -> String) -> String {
        let target = normalized(text)
        let map = Alignment(source: units, target: target).sourceToTarget
        // Второй перевод строки каждого разделителя кусков — там, куда его отнесло сравнение.
        let dropped = Set(segmentRanges.dropFirst().compactMap { map[$0.lowerBound - 1] })
        var result = String(decoding: target.enumerated().filter { !dropped.contains($0.offset) }.map(\.element), as: UTF16.self)
        for (index, token) in tokens.enumerated().reversed() {
            result = result.replacingOccurrences(of: "⟦\(index + 1)⟧", with: visible(token.original))
        }
        return result
    }
}

/// Сравнение «было → стало» по знакам UTF-16: совпавшие пары и куски замен.
struct Alignment {
    struct Hunk {
        let source: Range<Int>
        let target: Range<Int>
    }

    private(set) var pairs: [(Int, Int)] = []
    private(set) var hunks: [Hunk] = []
    private(set) var sourceToTarget: [Int?]

    init(source: [unichar], target: [unichar]) {
        sourceToTarget = [Int?](repeating: nil, count: source.count)
        let difference = target.difference(from: source)
        var removed = IndexSet(), inserted = IndexSet()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var i = 0, j = 0
        var hunkSource = 0, hunkTarget = 0, inHunk = false
        func closeHunk() {
            if inHunk { hunks.append(Hunk(source: hunkSource..<i, target: hunkTarget..<j)) }
            inHunk = false
        }
        while i < source.count || j < target.count {
            let removes = i < source.count && removed.contains(i)
            let inserts = j < target.count && inserted.contains(j)
            if removes || inserts || i >= source.count || j >= target.count {
                if !inHunk { inHunk = true; hunkSource = i; hunkTarget = j }
                if removes || j >= target.count { i += 1 } else { j += 1 }
                continue
            }
            closeHunk()
            pairs.append((i, j))
            sourceToTarget[i] = j
            i += 1
            j += 1
        }
        closeHunk()
    }
}

extension InlineText {
    /// Кусок `range` (UTF-16) со своим оформлением.
    public func slice(_ range: Range<Int>) -> InlineText {
        let units = Array(string.utf16)
        let range = max(0, range.lowerBound)..<min(units.count, max(range.lowerBound, range.upperBound))
        let runs = runs.compactMap { run -> StyledRun? in
            let start = max(run.start, range.lowerBound), end = min(run.start + run.length, range.upperBound)
            return start < end ? StyledRun(start: start - range.lowerBound, length: end - start, style: run.style) : nil
        }
        return InlineText(String(decoding: units[range], as: UTF16.self), runs: runs).normalized()
    }

    /// Текст, где кусок `range` заменён на `replacement`; оформление за краями сдвигается.
    public func replacing(_ range: Range<Int>, with replacement: InlineText) -> InlineText {
        let units = Array(string.utf16)
        let delta = replacement.string.utf16.count - range.count
        var runs: [StyledRun] = []
        for run in self.runs {
            let end = run.start + run.length
            if end <= range.lowerBound { runs.append(run); continue }
            if run.start >= range.upperBound { runs.append(StyledRun(start: run.start + delta, length: run.length, style: run.style)); continue }
            if run.start < range.lowerBound { runs.append(StyledRun(start: run.start, length: range.lowerBound - run.start, style: run.style)) }
            if end > range.upperBound {
                runs.append(StyledRun(start: range.upperBound + delta, length: end - range.upperBound, style: run.style))
            }
        }
        runs += replacement.runs.map { StyledRun(start: $0.start + range.lowerBound, length: $0.length, style: $0.style) }
        let string = String(decoding: units[..<range.lowerBound] + Array(replacement.string.utf16) + units[range.upperBound...], as: UTF16.self)
        return InlineText(string, runs: runs).normalized()
    }
}
