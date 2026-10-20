import Foundation
import Testing
import NotesCore
@testable import MarkdownExport

/// Упоминания и даты в Markdown (contracts/markdown-and-notion.md; tasks.md T058).
@Suite("Упоминания и даты в Markdown")
struct MentionDateExportTests {
    private let pageId = UUID()
    private let writer = MarkdownBlockWriter()
    private let plan = UUID()

    private func markdown(_ text: InlineText, kind: BlockKind = .paragraph, links: [UUID: PageLinkTarget] = [:]) -> String {
        writer.markdown(for: [Block(pageId: pageId, kind: kind, text: text, sortKey: .between(nil, nil))], resolveLink: { links[$0] })
    }

    private func atom(_ prefix: String, _ style: InlineStyle, _ suffix: String = "") -> InlineText {
        let start = (prefix as NSString).length
        return InlineText(prefix + "\u{FFFC}" + suffix, runs: [StyledRun(start: start, length: 1, style: style)])
    }

    @Test("Упоминание — ссылка на файл страницы с иконкой и названием")
    func mentionLinksToFile() {
        let links = [plan: PageLinkTarget(title: "План [Q4]", path: "../Работа/План.md", icon: "📘")]
        #expect(markdown(atom("Смотри ", .mention(plan), " завтра"), links: links)
            == "Смотри [📘 План \\[Q4\\]](../%D0%A0%D0%B0%D0%B1%D0%BE%D1%82%D0%B0/%D0%9F%D0%BB%D0%B0%D0%BD.md) завтра\n"
            .removingPercentEncoding!)
    }

    @Test("Упоминание в жирном и в пункте списка")
    func mentionInsideFormatting() {
        let links = [plan: PageLinkTarget(title: "План", path: "План.md")]
        var text = atom("см ", .mention(plan))
        text.runs.append(StyledRun(start: 0, length: 4, style: .bold))
        #expect(markdown(text, links: links) == "**см [План](План.md)**\n")
        #expect(markdown(atom("", .mention(plan)), kind: .bulletItem, links: links) == "- [План](План.md)\n")
    }

    @Test("Страница не выгружена — название простым текстом; нет совсем — «Удалённая страница»")
    func mentionWithoutFile() {
        let links = [plan: PageLinkTarget(title: "Старое", path: nil)]
        #expect(markdown(atom("а ", .mention(plan)), links: links) == "а Старое\n")
        #expect(markdown(atom("а ", .mention(UUID()))) == "а Удалённая страница\n")
    }

    @Test("Дата — <time datetime> с поясом и словами; с напоминанием — data-remind в UTC")
    func dates() {
        let day = DateMention(start: "2026-10-20", includesTime: false, timeZone: "Europe/Moscow")
        #expect(markdown(atom("до ", .date(day))) == #"до <time datetime="2026-10-20" data-timezone="Europe/Moscow">20 октября 2026</time>"# + "\n")

        let fireAt = ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z")!
        let meeting = DateMention(start: "2026-10-20T09:00", includesTime: true, timeZone: "Asia/Makassar",
                                  reminder: DateMention.Reminder(fireAt: fireAt))
        #expect(markdown(atom("", .date(meeting)))
            == #"<time datetime="2026-10-20T09:00+08:00" data-timezone="Asia/Makassar" data-remind="2026-10-20T00:00:00Z">20 октября 2026, 9:00</time>"# + "\n")
    }
}
