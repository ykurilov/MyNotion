import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor

/// Шаблоны в редакторе (003, US7, contracts/pages-ui.md, «Шаблоны на пустой странице»): «@сегодня» и «@сейчас»
/// в шаблоне помечаются, строки шаблонов — на пустой странице, ↑↓ и Enter, пропадают от текста.
@MainActor
@Suite("Шаблоны в редакторе")
struct TemplateRowsTests {
    static func choices(_ count: Int) -> [TemplateChoice] {
        (1...count).map { TemplateChoice(id: UUID(), title: "Шаблон \($0)", icon: $0 == 1 ? "📞" : nil) }
    }

    // MARK: Даты шаблона

    @Test("«@» на странице-шаблоне: «Сегодня» и «Сейчас» помечены; вне шаблона слова «Сейчас» нет и меток нет")
    func templateSuggestions() {
        let now = DateQueryTests.now, calendar = DateQueryTests.calendar
        let inTemplate = DateQuery.suggestions(for: "", now: now, calendar: calendar, isTemplate: true)
        #expect(inTemplate.map(\.title) == ["Сегодня", "Завтра", "Вчера", "Через неделю", "Сейчас"])
        #expect(inTemplate.map(\.mention.templateRelative) == [.today, nil, nil, nil, .now])
        #expect(inTemplate.last?.mention.includesTime == true)
        #expect(DateQuery.suggestions(for: "сей", now: now, calendar: calendar, isTemplate: true).map(\.title) == ["Сейчас"])

        let plain = DateQuery.suggestions(for: "", now: now, calendar: calendar)
        #expect(plain.map(\.title) == ["Сегодня", "Завтра", "Вчера", "Через неделю"])
        #expect(plain.allSatisfy { $0.mention.templateRelative == nil })
        #expect(DateQuery.suggestions(for: "сей", now: now, calendar: calendar).isEmpty)
    }

    @Test("Ручная правка дня или времени снимает метку шаблона; смена напоминания — нет")
    func manualEditClearsTemplateMark() {
        let date = DateMention(start: "2026-10-19", includesTime: false, timeZone: "Europe/Moscow", templateRelative: .today)
        #expect(date.edited(day: DateComponents(year: 2026, month: 10, day: 25)).templateRelative == nil)
        #expect(date.edited(includesTime: true, time: (10, 0)).templateRelative == nil)
        #expect(date.edited(reminder: .atEvent).templateRelative == .today)
    }

    @Test("«@сегодня» в странице-шаблоне ставит дату с меткой; в обычной странице — без метки")
    func atTodayInTemplateAndPlainPage() throws {
        for isTemplate in [true, false] {
            let editor = try EditorFixture([.paragraph()], isTemplate: isTemplate)
            editor.textView.now = { DateQueryTests.now }
            editor.textView.calendar = DateQueryTests.calendar
            editor.placeCaret(inBlock: 0)
            editor.type("@сегодня")
            editor.press(#selector(NSResponder.insertNewline(_:)))
            let run = try #require(editor.document.blocks[0].text.runs.first)
            guard case .date(let date) = run.style else { Issue.record("не дата: \(run.style)"); return }
            #expect(date.templateRelative == (isTemplate ? .today : nil))
        }
    }

    // MARK: Строки шаблонов

    @Test("Пустая страница: строки до пяти и «Ещё шаблоны…»; при пяти и меньше — без «Ещё»")
    func rowsOnEmptyPage() throws {
        let editor = try EditorFixture([.paragraph()])
        editor.textView.templateChoices = Self.choices(3)
        let rows = try #require(editor.textView.templateRows)
        #expect(rows.isVisible)
        #expect(rows.rowCount == 3)

        editor.textView.templateChoices = Self.choices(8)
        #expect(editor.textView.templateRows?.rowCount == 6, "пять шаблонов и «Ещё шаблоны…»")
    }

    @Test("Заголовок «Шаблоны» и иконки строк — по левому краю названия страницы (T101 № 12)")
    func rowsAlignWithTitle() throws {
        let editor = try EditorFixture([.paragraph()])
        editor.textView.showIcon(nil)
        editor.textView.templateChoices = [TemplateChoice(id: UUID(), title: "Шаблон: заметки встречи", icon: "🗓️"),
                                           TemplateChoice(id: UUID(), title: "Шаблон: отчёт", icon: nil)]
        editor.textView.layoutSubtreeIfNeeded()
        let rows = try #require(editor.textView.templateRows)
        rows.container.layoutSubtreeIfNeeded()
        rows.rows.forEach { $0.layoutSubtreeIfNeeded() }
        let pixels = try ViewPixels(editor.textView, appearance: .aqua)
        let header = editor.textView.header
        let titleArea = header.convert(header.titleField.frame, to: editor.textView)
        let title = try #require(pixels.inkBounds(in: titleArea))
        let headingArea = rows.container.convert(rows.heading.frame, to: editor.textView)
        let heading = try #require(pixels.inkBounds(in: headingArea))
        #expect(abs(heading.minX - title.minX) <= 1.5, "заголовок \(heading.minX), название \(title.minX)")
        for row in rows.rows {
            let iconArea = row.convert(NSRect(x: 0, y: 0, width: 26, height: row.bounds.height), to: editor.textView)
            let icon = try #require(pixels.inkBounds(in: iconArea))
            #expect(abs(icon.minX - title.minX) <= 1, "иконка строки \(icon.minX), название \(title.minX)")
        }
    }

    @Test("Поиск «Ещё шаблоны…» — высотой по найденному, без пустоты внизу, не выше 8 строк (T101 № 13)")
    func searchCardFitsRows() {
        let six = TemplateSearchPopover(choices: Self.choices(6)) { _ in }
        #expect(TemplateSearchPopover.height(forRows: 6) == TemplateSearchPopover.listTop + 6 * TemplateRowView.height + 4)
        #expect(six.rows.count == 6)
        #expect(TemplateSearchPopover.height(forRows: 20) == TemplateSearchPopover.listTop + 8 * TemplateRowView.height + 4)
        #expect(TemplateSearchPopover.height(forRows: 0) == TemplateSearchPopover.listTop + TemplateRowView.height + 4)
    }

    @Test("Строк нет: нет шаблонов, страница с текстом, страница не пуста, сама страница — шаблон")
    func noRowsWhenNotOffered() throws {
        let withText = try EditorFixture([.paragraph("уже есть")])
        withText.textView.templateChoices = Self.choices(2)
        #expect(withText.textView.templateRows?.isVisible != true)

        let twoBlocks = try EditorFixture([.paragraph(), .paragraph()])
        twoBlocks.textView.templateChoices = Self.choices(2)
        #expect(twoBlocks.textView.templateRows?.isVisible != true)

        let template = try EditorFixture([.paragraph()], isTemplate: true)
        template.textView.templateChoices = Self.choices(2)
        #expect(template.textView.templateRows?.isVisible != true)

        let noTemplates = try EditorFixture([.paragraph()])
        #expect(noTemplates.textView.templateRows == nil, "без шаблонов виды даже не создаются")
    }

    @Test("Как только в странице появился текст, строки пропадают; текст стёрт — возвращаются")
    func rowsDisappearOnTyping() throws {
        let editor = try EditorFixture([.paragraph()])
        editor.textView.templateChoices = Self.choices(2)
        editor.placeCaret(inBlock: 0)
        #expect(editor.textView.templateRows?.isVisible == true)

        editor.type("п")
        #expect(editor.textView.templateRows?.isVisible == false)

        editor.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(editor.textView.templateRows?.isVisible == true)
    }

    @Test("↓ выбирает первую строку, ещё ↓ — вторую, ↑ возвращает; Enter выбирает шаблон, без выбора — обычный Enter")
    func arrowsAndEnter() throws {
        let editor = try EditorFixture([.paragraph()])
        let choices = Self.choices(3)
        editor.textView.templateChoices = choices
        var chosen: [UUID] = []
        editor.textView.onChooseTemplate = { chosen.append($0) }
        editor.placeCaret(inBlock: 0)
        let rows = try #require(editor.textView.templateRows)

        #expect(rows.selectedIndex == nil)
        editor.press(#selector(NSResponder.moveDown(_:)))
        editor.press(#selector(NSResponder.moveDown(_:)))
        #expect(rows.selectedIndex == 1)
        editor.press(#selector(NSResponder.moveUp(_:)))
        #expect(rows.selectedIndex == 0)
        editor.press(#selector(NSResponder.moveUp(_:)))
        #expect(rows.selectedIndex == nil)

        editor.press(#selector(NSResponder.moveDown(_:)))
        editor.press(#selector(NSResponder.moveDown(_:)))
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(chosen == [choices[1].id])
    }

    @Test("Щелчок по строке выбирает шаблон; строки прячутся")
    func clickChoosesTemplate() throws {
        let editor = try EditorFixture([.paragraph()])
        let choices = Self.choices(2)
        editor.textView.templateChoices = choices
        var chosen: [UUID] = []
        editor.textView.onChooseTemplate = { chosen.append($0) }

        editor.textView.chooseTemplate(choices[0].id)

        #expect(chosen == [choices[0].id])
        #expect(editor.textView.templateRows?.isVisible == false)
    }
}
