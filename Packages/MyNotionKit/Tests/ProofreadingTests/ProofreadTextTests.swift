import Foundation
import NotesCore
import Testing
@testable import Proofreading

/// Строки с упоминанием: «⟦X⟧» в записи теста — знак U+FFFC с упоминанием страницы.
enum InlineTextFixture {
    static let pageId = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    static func replacingMarker(_ text: InlineText) -> InlineText {
        guard let range = text.string.range(of: "⟦X⟧") else { return text }
        let start = text.string.utf16.distance(from: text.string.utf16.startIndex, to: range.lowerBound.samePosition(in: text.string.utf16)!)
        let string = text.string.replacingCharacters(in: range, with: "\u{FFFC}")
        return InlineText(string, runs: text.runs + [StyledRun(start: start, length: 1, style: .mention(pageId))]).normalized()
    }
}

@Suite("Перенос оформления")
struct ProofreadTextTests {
    private func run(_ text: String, _ part: String, _ style: InlineStyle) -> StyledRun {
        let range = (text as NSString).range(of: part)
        return StyledRun(start: range.location, length: range.length, style: style)
    }

    @Test("Простой текст уходит как есть и возвращается исправленным")
    func plain() throws {
        let text = ProofreadText(segments: [InlineText("превет как дила")])
        #expect(text.source == "превет как дила")
        #expect(text.hasChanges("привет, как дела?"))
        #expect(try text.apply("привет, как дела?") == [InlineText("привет, как дела?")])
    }

    @Test("Без правок изменений нет; пробелы по краям, срезанные моделью, не считаются правкой")
    func noChanges() throws {
        let text = ProofreadText(segments: [InlineText("  Всё верно. ")])
        #expect(!text.hasChanges("Всё верно."))
        #expect(try text.apply("Всё верно!") == [InlineText("  Всё верно! ")])
    }

    @Test("Жирное слово с опечаткой остаётся жирным, курсив рядом — курсивом")
    func boldWord() throws {
        let source = "Это очнь важно сегодня"
        let original = InlineText(source, runs: [run(source, "очнь важно", .bold), run(source, "сегодня", .italic)]).normalized()
        let result = try ProofreadText(segments: [original]).apply("Это очень важно сегодня")
        let fixed = "Это очень важно сегодня"
        #expect(result == [InlineText(fixed, runs: [run(fixed, "очень важно", .bold), run(fixed, "сегодня", .italic)]).normalized()])
    }

    @Test("Запятая сразу после ссылки — не часть ссылки; буква внутри ссылки — часть")
    func linkEdges() throws {
        let url = URL(string: "https://example.com")!
        let source = "Смотри сайт кампании и пиши"
        let original = InlineText(source, runs: [run(source, "сайт кампании", .link(url))]).normalized()
        let result = try ProofreadText(segments: [original]).apply("Смотри сайт компании, и пиши")
        let fixed = "Смотри сайт компании, и пиши"
        #expect(result == [InlineText(fixed, runs: [run(fixed, "сайт компании", .link(url))]).normalized()])
    }

    @Test("Упоминание и код уходят метками и возвращаются на место без изменений")
    func atomsAndCode() throws {
        let source = "Открой ⟦X⟧ и запусти npm instal прям сейчас"
        var original = InlineTextFixture.replacingMarker(InlineText(source))
        let string = original.string
        original.runs.append(run(string, "npm instal", .code))
        original = original.normalized()
        let text = ProofreadText(segments: [original])
        #expect(text.source == "Открой ⟦1⟧ и запусти ⟦2⟧ прям сейчас")
        let result = try text.apply("Открой ⟦1⟧ и запусти ⟦2⟧ прямо сейчас")
        let fixedString = string.replacingOccurrences(of: "прям", with: "прямо")
        #expect(result[0].string == fixedString)
        #expect(result[0].runs.contains(run(fixedString, "npm instal", .code)), "Код не исправлен и остался кодом")
        #expect(result[0].runs.contains(StyledRun(start: 7, length: 1, style: .mention(InlineTextFixture.pageId))))
    }

    @Test("Потерянная или изменённая метка — оформление не сохранить, текст не трогаем", arguments: [
        "Открой и запусти ⟦2⟧", "Открой ⟦1⟧ и запусти ⟦2⟧ ⟦2⟧", "Открой ⟦12⟧ и запусти ⟦2⟧", "Открой ⟦2⟧ и запусти ⟦1⟧",
    ])
    func lostMarks(corrected: String) {
        var original = InlineTextFixture.replacingMarker(InlineText("Открой ⟦X⟧ и запусти код"))
        original.runs.append(run(original.string, "код", .code))
        let text = ProofreadText(segments: [original.normalized()])
        #expect(throws: ProofreadingError.formattingLost) { try text.apply(corrected) }
    }

    @Test("Несколько блоков: граница блока — пустая строка, она обязана вернуться; переносы внутри блока — тоже")
    func blocks() throws {
        let text = ProofreadText(segments: [InlineText("перваяя строка"), InlineText("вторая\nстрочька"), InlineText("третья")])
        #expect(text.source == "перваяя строка\n\nвторая\nстрочька\n\nтретья")
        let result = try text.apply("Первая строка\n\nвторая\nстрочка\n\nтретья.")
        #expect(result == [InlineText("Первая строка"), InlineText("вторая\nстрочка"), InlineText("третья.")])
        #expect(throws: ProofreadingError.formattingLost) { try text.apply("Первая строка вторая\nстрочка\n\nтретья") }
        #expect(throws: ProofreadingError.formattingLost) { try text.apply("Первая строка\n\nвторая строчка\n\nтретья") }
        #expect(throws: ProofreadingError.formattingLost) { try text.apply("Первая\n\nстрока\n\nвторая\nстрочка\n\nтретья") }
    }

    @Test("Цвет и подчёркивание через границу заменённого слова переносятся")
    func colors() throws {
        let source = "красный тикст тут"
        let original = InlineText(source, runs: [run(source, "красный тикст", .textColor(.red)), run(source, "тикст тут", .underline)]).normalized()
        let fixed = "красный текст тут"
        let result = try ProofreadText(segments: [original]).apply(fixed)
        #expect(result == [InlineText(fixed, runs: [run(fixed, "красный текст", .textColor(.red)), run(fixed, "текст тут", .underline)]).normalized()])
    }

    @Test("Кусок и замена куска: оформление за краями сдвигается, через край — режется и сливается")
    func sliceAndReplace() {
        let source = "один два три"
        let text = InlineText(source, runs: [run(source, "один два", .bold)]).normalized()
        let middle = text.slice(5..<8)
        #expect(middle == InlineText("два", runs: [StyledRun(start: 0, length: 3, style: .bold)]))
        let replaced = text.replacing(5..<8, with: InlineText("двадцать", runs: [StyledRun(start: 0, length: 8, style: .bold)]))
        let fixed = "один двадцать три"
        #expect(replaced == InlineText(fixed, runs: [run(fixed, "один двадцать", .bold)]))
    }

    @Test("Для окна: метки показываются видимым текстом, граница блоков — одной строкой")
    func display() {
        var original = InlineTextFixture.replacingMarker(InlineText("см. ⟦X⟧ и x+1"))
        original.runs.append(run(original.string, "x+1", .code))
        let text = ProofreadText(segments: [original.normalized(), InlineText("второй")])
        #expect(text.displayText(of: text.source, visible: { $0.plainText(pageTitle: { _ in "@Страница" }) }) == "см. @Страница и x+1\nвторой")
    }
}

@Suite("Правки по словам")
struct WordDiffTests {
    @Test("Замена слова и вставка знаков: зачёркнутое, затем новое")
    func pieces() {
        #expect(WordDiff.pieces(from: "превет как дила", to: "привет, как дела?") == [
            .init(.removed, "превет"), .init(.inserted, "привет,"), .init(.same, " как "),
            .init(.removed, "дила"), .init(.inserted, "дела?"),
        ])
    }

    @Test("Без правок — один кусок")
    func same() {
        #expect(WordDiff.pieces(from: "Всё хорошо.", to: "Всё хорошо.") == [.init(.same, "Всё хорошо.")])
    }

    @Test("Слова: дефис внутри слова, знаки и пробелы отдельно")
    func tokens() {
        #expect(WordDiff.tokens(of: "кто-то, да  ⟦1⟧!") == ["кто-то", ",", " ", "да", "  ", "⟦1⟧", "!"])
    }
}
