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
enum SelectionMapping {
    static func map(_ selection: NSRange, from old: String, to new: String) -> NSRange {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        var prefix = 0
        let limit = min(oldUnits.count, newUnits.count)
        while prefix < limit, oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] { suffix += 1 }
        let oldChangedEnd = oldUnits.count - suffix
        let newChangedLength = newUnits.count - suffix - prefix
        let delta = newUnits.count - oldUnits.count

        func position(_ location: Int) -> Int {
            if location < prefix { return location }
            if location >= oldChangedEnd { return location + delta }
            return prefix + min(location - prefix, newChangedLength)
        }
        let start = position(selection.location)
        let end = max(start, position(selection.location + selection.length))
        return NSRange(location: start, length: end - start)
    }
}
