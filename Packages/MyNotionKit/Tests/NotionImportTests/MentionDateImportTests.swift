import Foundation
import Testing
import NotesCore
@testable import NotionImport

/// Даты и упоминания из выгрузки Notion и из нашей выгрузки (contracts/markdown-and-notion.md; tasks.md T058).
@Suite("Упоминания и даты при импорте")
struct MentionDateImportTests {
    private func dates(_ text: InlineText) -> [DateMention] {
        text.runs.compactMap { if case .date(let date) = $0.style { date } else { nil } }
    }

    @Test("«@October 20, 2026» и «@20 октября 2026» — дата без напоминания")
    func notionDates() throws {
        let english = NotionInlineParser.parse("Сдать @October 20, 2026 отчёт").text
        #expect(english.string == "Сдать \u{FFFC} отчёт")
        let date = try #require(dates(english).first)
        #expect(date.start == "2026-10-20")
        #expect(date.includesTime == false)
        #expect(date.reminder == nil)

        let withTime = try #require(dates(NotionInlineParser.parse("@October 20, 2026 9:30 PM").text).first)
        #expect(withTime.start == "2026-10-20T21:30")
        #expect(withTime.includesTime)

        let russian = NotionInlineParser.parse("до @20 октября 2026").text
        #expect(russian.string == "до \u{FFFC}")
        #expect(dates(russian).first?.start == "2026-10-20")
        // Не дата — текст как есть.
        #expect(NotionInlineParser.parse("почта yury@mail.ru").text.string == "почта yury@mail.ru")
    }

    @Test("Наша <time> читается обратно: день, время, пояс и напоминание")
    func ownTimeTag() throws {
        let parsed = NotionInlineParser.parse(
            #"<time datetime="2026-10-20T09:00+08:00" data-timezone="Asia/Makassar" data-remind="2026-10-20T00:00:00Z">20 октября 2026, 9:00</time> встреча"#)
        #expect(parsed.text.string == "\u{FFFC} встреча")
        let date = try #require(dates(parsed.text).first)
        #expect(date.start == "2026-10-20T09:00")
        #expect(date.timeZone == "Asia/Makassar")
        #expect(date.reminder?.fireAt == ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z"))

        let day = try #require(dates(NotionInlineParser.parse(#"<time datetime="2026-10-21">21 октября 2026</time>"#).text).first)
        #expect(day.start == "2026-10-21")
        #expect(day.includesTime == false)
    }

    @Test("Ссылка на страницу выгрузки внутри текста — упоминание; вся строка-ссылка — по-прежнему блок-подстраница")
    func pageLinksInsideText() throws {
        let parsed = NotionInlineParser.parse("Смотри [План](%D0%9F%D0%BB%D0%B0%D0%BD%201f2a3b4c5d6e7f8091a2b3c4d5e6f701.md) сегодня")
        #expect(parsed.text.string == "Смотри \u{FFFC} сегодня")
        let mention = try #require(parsed.pageMentions.first)
        #expect(mention.path == "План 1f2a3b4c5d6e7f8091a2b3c4d5e6f701.md")
        #expect(mention.title == "План")
        #expect(parsed.text.runs.contains { $0.style == .mention(mention.placeholder) })
        #expect(NotionInlineParser.parse("[План](План.md)").soleLink == .page("План.md"))
    }

    @Test("Импорт: упоминание найденной страницы ведёт на неё, ненайденной — название текстом")
    func importerResolvesMentions() throws {
        let found = UUID()
        let placeholder = UUID(), missing = UUID()
        let text = InlineText("а \u{FFFC} б \u{FFFC}", runs: [StyledRun(start: 2, length: 1, style: .mention(placeholder)),
                                                         StyledRun(start: 6, length: 1, style: .mention(missing))])
        let mentions = [NotionPageMention(placeholder: placeholder, path: "План.md", title: "План"),
                        NotionPageMention(placeholder: missing, path: "Нет.md", title: "Нет такой")]
        let resolved = NotionImporter.resolvingMentions(in: text, mentions: mentions) { $0 == "План.md" ? found : nil }
        #expect(resolved.string == "а \u{FFFC} б Нет такой")
        #expect(resolved.runs == [StyledRun(start: 2, length: 1, style: .mention(found))])
    }
}
