import AppKit

extension NSTextLayoutManager {
    /// Разложить текст с начала до абзаца с `location` включительно — перед тем как спрашивать, где этот абзац.
    /// TextKit раскладывает лениво: абзац, разложенный раньше абзацев над ним (правка сбросила их раскладку, а место
    /// абзаца спросили первым), встаёт на прикидочное место, и раскладка абзацев выше его уже не двигает (проба T003).
    /// Курсор и подсказка легли бы на чужую строку (баг Юрия 25.10.2026: стёр текст пункта под заголовком —
    /// курсор и «Список» поверх заголовка, маркер на месте).
    func ensureLayoutFromStart(through location: NSTextLocation) {
        ensureLayout(for: NSTextRange(location: documentRange.location, end: location) ?? NSTextRange(location: location))
        ensureLayout(for: NSTextRange(location: location))
    }
}
