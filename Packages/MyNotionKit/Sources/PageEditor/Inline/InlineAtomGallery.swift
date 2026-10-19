import AppKit
import NotesCore

/// Упоминания и даты в галерее интерфейса (`--ui-gallery`): страница-образец и сцены окна «@» и календарика.
public enum InlineAtomGallery {
    /// Страница, на которую ссылается образец: галерея создаёт её с этим id.
    public static let mentionTargetId = UUID(uuidString: "0193A5E1-0000-7000-8000-00000000A001")!
    public static let mentionTargetTitle = "Планы на квартал"
    public static let mentionTargetIcon = "📘"

    private static func atom(_ prefix: String, _ styles: [InlineStyle], separator: String = " и ") -> InlineText {
        var string = prefix
        var runs: [StyledRun] = []
        for (index, style) in styles.enumerated() {
            if index > 0 { string += separator }
            runs.append(StyledRun(start: (string as NSString).length, length: 1, style: style))
            string += "\u{FFFC}"
        }
        return InlineText(string, runs: runs)
    }

    private static func block(_ text: InlineText) -> BlockGallerySample.SampleBlock {
        var block = BlockGallerySample.SampleBlock(.paragraph)
        block.text = text
        return block
    }

    static let samples: [BlockGallerySample] = {
        let iso = ISO8601DateFormatter()
        let past = DateMention(start: "2020-05-01T09:00", includesTime: true, timeZone: "Europe/Moscow",
                               reminder: DateMention.Reminder(fireAt: iso.date(from: "2020-05-01T06:00:00Z")!))
        let future = DateMention(start: "2030-01-15T10:00", includesTime: true, timeZone: "Europe/Moscow",
                                 reminder: DateMention.Reminder(fireAt: iso.date(from: "2030-01-15T07:00:00Z")!))
        let day = DateMention(start: "2030-10-20", includesTime: false, timeZone: "Europe/Moscow")
        return [BlockGallerySample(id: "mentions-and-dates", summary: "Упоминания и даты", blocks: [
            block(atom("Смотри ", [.mention(mentionTargetId), .mention(UUID(uuidString: "0193A5E1-0000-7000-8000-00000000A0FF")!)])),
            block(atom("Сдать отчёт ", [.date(day)])),
            block(atom("Созвон ", [.date(future)])),
            block(atom("Просрочено ", [.date(past)])),
            BlockGallerySample.SampleBlock(.paragraph),
        ], narrowToo: false),
        BlockGallerySample(id: "equation-inline", summary: "Формулы в строке: дробь, корень, пустая и неверная", blocks: [
            block(atom("Площадь круга ", [.equation("\\pi r^2")], separator: "")),
            block(atom("Корни: ", [.equation("x_{1,2} = \\frac{-b \\pm \\sqrt{D}}{2a}"), .equation("\\sqrt[3]{8} = 2")])),
            block(atom("Пустая и неверная: ", [.equation(""), .equation("\\frac{1}{")])),
        ], narrowToo: false)]
    }()

    /// Окно «@» открыто.
    @MainActor
    public static func isMentionPickerOpen(in window: NSWindow) -> Bool {
        PageEditorPreview.textView(in: window)?.mentionPicker.isOpen == true
    }

    /// Открыть календарик первой даты страницы, как по щелчку. `false` — даты нет.
    @MainActor
    @discardableResult
    public static func openFirstDatePicker(in window: NSWindow) -> Bool {
        guard let textView = PageEditorPreview.textView(in: window), let storage = textView.textStorage else { return false }
        var index: Int?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value is DateMentionAttachment {
                index = range.location
                stop.pointee = true
            }
        }
        guard let index else { return false }
        textView.scrollRangeToVisible(NSRange(location: index, length: 1))
        textView.openAtom(atCharacter: index)
        return textView.inlineAtoms.datePopover.isOpen
    }
}
