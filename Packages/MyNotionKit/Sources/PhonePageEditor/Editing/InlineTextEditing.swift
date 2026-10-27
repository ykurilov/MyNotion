import Foundation
import NotesCore

/// Правки текста блока целиком со стилями: разрез по Enter, склейка по ⌫ в начале блока, стили набора.
/// Смещения — в единицах UTF-16, как у `InlineText` и `UITextView`.
extension InlineText {
    var utf16Count: Int { string.utf16.count }

    /// Текст до `offset` и после него; отрезки стилей режутся по месту, атом целиком уходит в свою половину.
    func split(at offset: Int) -> (head: InlineText, tail: InlineText) {
        let units = Array(string.utf16)
        let cut = min(max(offset, 0), units.count)
        var headRuns: [StyledRun] = []
        var tailRuns: [StyledRun] = []
        for run in runs {
            let end = run.start + run.length
            if run.start < cut {
                headRuns.append(StyledRun(start: run.start, length: min(end, cut) - run.start, style: run.style))
            }
            if end > cut {
                let start = max(run.start, cut)
                tailRuns.append(StyledRun(start: start - cut, length: end - start, style: run.style))
            }
        }
        let head = InlineText(String(decoding: units[..<cut], as: UTF16.self), runs: headRuns).normalized()
        let tail = InlineText(String(decoding: units[cut...], as: UTF16.self), runs: tailRuns).normalized()
        return (head, tail)
    }

    /// Этот текст и следом `other`; отрезки `other` сдвигаются на длину этого.
    func appending(_ other: InlineText) -> InlineText {
        let shift = utf16Count
        let shifted = other.runs.map { StyledRun(start: $0.start + shift, length: $0.length, style: $0.style) }
        return InlineText(string + other.string, runs: runs + shifted).normalized()
    }

    /// Оформление знаков, набранных на месте `offset`: как у знака перед курсором (в начале — как у первого).
    /// Ссылка и атомы (упоминание, дата, формула) на новый текст не переходят — как в Notion.
    func typingStyles(at offset: Int) -> [InlineStyle] {
        let length = utf16Count
        guard length > 0 else { return [] }
        let source = min(max(offset - 1, 0), length - 1)
        return runs.filter { run in
            run.start <= source && source < run.start + run.length && !run.style.isAtom && !run.style.isLink
        }.map(\.style)
    }
}

extension InlineStyle {
    var isLink: Bool {
        if case .link = self { true } else { false }
    }
}

/// Где оказаться курсору, когда текст блока поменялся не от набора (правка с другого устройства).
/// Общее начало и общий конец старого и нового текста остаются на местах; курсор за изменённой частью сдвигается
/// вместе с текстом, курсор внутри убранного — встаёт в её начало, внутри заменённого — не дальше нового текста.
/// Границы — только между знаками: смайлик из двух половинок UTF-16 или из нескольких смайликов не разрезается.
enum SelectionMapping {
    static func map(_ selection: NSRange, from old: String, to new: String) -> NSRange {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        var prefix = 0
        let limit = min(oldUnits.count, newUnits.count)
        while prefix < limit, oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        prefix = min(characterStart(prefix, in: old), characterStart(prefix, in: new))
        var suffix = 0
        while suffix < limit - prefix, oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] { suffix += 1 }
        suffix = min(oldUnits.count - characterEnd(oldUnits.count - suffix, in: old),
                     newUnits.count - characterEnd(newUnits.count - suffix, in: new))
        let oldChangedEnd = oldUnits.count - suffix
        let newChangedLength = newUnits.count - suffix - prefix
        let delta = newUnits.count - oldUnits.count

        func position(_ location: Int) -> Int {
            if location < prefix { return location }
            if location >= oldChangedEnd { return location + delta }
            return characterStart(prefix + min(location - prefix, newChangedLength), in: new)
        }
        let start = position(selection.location)
        let end = max(start, position(selection.location + selection.length))
        return NSRange(location: start, length: end - start)
    }

    /// Начало знака, внутри которого `offset` (или сам `offset`, если он уже между знаками).
    private static func characterStart(_ offset: Int, in string: String) -> Int {
        let text = string as NSString
        guard offset > 0, offset < text.length else { return offset }
        return text.rangeOfComposedCharacterSequence(at: offset).location
    }

    /// Конец знака, внутри которого `offset` (или сам `offset`, если он уже между знаками).
    private static func characterEnd(_ offset: Int, in string: String) -> Int {
        let text = string as NSString
        guard offset > 0, offset < text.length else { return offset }
        let range = text.rangeOfComposedCharacterSequence(at: offset)
        return range.location == offset ? offset : NSMaxRange(range)
    }
}
