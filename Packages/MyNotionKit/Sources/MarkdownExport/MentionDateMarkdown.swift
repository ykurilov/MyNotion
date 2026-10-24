import Foundation
import NotesCore

/// Упоминания и даты в Markdown (contracts/markdown-and-notion.md): упоминание — ссылка на файл страницы
/// `[📘 Название](../Название.md)`, как блок-подстраница; дата — `<time datetime="…">20 октября 2026, 9:00</time>`,
/// с напоминанием — `data-remind` в UTC. Пояс даты — `data-timezone`: импорт вернёт ту же дату.
enum MentionDateMarkdown {
    static func markdown(for atom: InlineStyle, resolveLink: (UUID) -> PageLinkTarget?, dateIds: Bool = false) -> String {
        switch atom {
        case .mention(let pageId): mention(pageId, target: resolveLink(pageId))
        case .date(let date): time(date, includesId: dateIds)
        default: ""
        }
    }

    private static func mention(_ pageId: UUID, target: PageLinkTarget?) -> String {
        guard let target else { return InlineText.deletedPageTitle }
        let title = escaped([target.icon, target.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "))
        guard let path = target.path else { return escaped(target.title) }
        return "[\(title)](\(InlineMarkdown.encodedPath(path)))"
    }

    private static func escaped(_ text: String) -> String {
        let units = Array(text.replacingOccurrences(of: "\n", with: " ").utf16)
        return InlineMarkdown.escape(units, range: 0..<units.count)
    }

    /// `includesId` — id даты (и её напоминания) в `data-id`: правка текста командой не меняет напоминание.
    static func time(_ date: DateMention, includesId: Bool = false) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: date.timeZone) ?? .current
        var datetime = date.start
        if date.includesTime, let moment = date.startDate {
            datetime += offsetText(calendar.timeZone.secondsFromGMT(for: moment))
        }
        var attributes = [("datetime", datetime), ("data-timezone", date.timeZone)]
        if let fireAt = date.reminder?.fireAt { attributes.append(("data-remind", fireAt.formatted(.iso8601))) }
        if includesId { attributes.append(("data-id", date.id.uuidString.lowercased())) }
        let attributeText = attributes.map { "\($0.0)=\"\(htmlEscaped($0.1))\"" }.joined(separator: " ")
        return "<time \(attributeText)>\(htmlEscaped(date.absoluteText(calendar: calendar)))</time>"
    }

    /// `+08:00`, `-03:30`.
    static func offsetText(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        return String(format: "%@%02d:%02d", sign, minutes / 60, minutes % 60)
    }

    private static func htmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension MarkdownWriteContext {
    /// Текст блока в Markdown с упоминаниями этой выгрузки — для писателей блоков 002 (`BlockWriters/`).
    func inlineMarkdown(_ text: InlineText) -> String {
        InlineMarkdown.render(text, resolveLink: resolveLink)
    }
}
