import AppKit
import NotesCore
import VisualStyle

/// Дата в тексте (contracts/blocks-and-keys.md, «Даты и напоминания»): «@Завтра 9:00» цветом textSecondary;
/// с напоминанием — будильник после даты; просроченная несделанная — красная.
final class DateMentionAttachment: InlineAtomAttachment, @unchecked Sendable {
    var date: DateMention? {
        if case .date(let date) = style { date } else { nil }
    }

    @MainActor
    override func pieces(in textView: PageTextView?, font: NSFont) -> [AtomPiece] {
        guard let date else { return [] }
        let now = textView?.now() ?? Date()
        let calendar = textView?.calendar ?? .current
        let color = Self.isOverdue(date, now: now, done: textView?.mentionDirectory.doneReminderIds ?? [])
            ? Palette.destructiveText : Palette.textSecondary
        var result: [AtomPiece] = [.text(date.shownText(now: now, calendar: calendar), font: font, color: color)]
        if date.reminder != nil, let alarm = NSImage(systemSymbolName: "alarm", accessibilityDescription: "Напоминание") {
            // Будильник — с размер текста, как у Notion: место значка во весь кегль (рисунок внутри чуть меньше).
            let size = font.pointSize
            result.append(AtomPiece(content: .space(font.pointSize * 0.25)))
            result.append(AtomPiece(content: .image(alarm, size: size, color: color)))
        }
        return result
    }

    /// Напоминание прошло, а «Готово» не нажали.
    static func isOverdue(_ date: DateMention, now: Date, done: Set<UUID>) -> Bool {
        guard let fireAt = date.reminder?.fireAt else { return false }
        return fireAt <= now && !done.contains(date.id)
    }
}
