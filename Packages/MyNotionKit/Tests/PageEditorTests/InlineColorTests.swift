import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Цвет текста и фона в строке (FR-112; contracts/blocks-and-keys.md, «Цвета»).
@MainActor
@Suite("Цвет в строке")
struct InlineColorTests {
    private func editor(_ specs: [EditorFixture.Spec]) throws -> EditorFixture {
        let editor = try EditorFixture(specs)
        editor.textView.recentColors = RecentColors(defaults: nil)
        return editor
    }

    private func run(_ start: Int, _ length: Int, _ style: InlineStyle) -> StyledRun {
        StyledRun(start: start, length: length, style: style)
    }

    private func text(_ color: NotionColor?) -> ColorChoice { ColorChoice(target: .text, color: color) }
    private func background(_ color: NotionColor?) -> ColorChoice { ColorChoice(target: .background, color: color) }

    // MARK: Клавиши

    @Test("⌘⇧H повторяет последний цвет; ⌘H свободна для системы")
    func keyBinding() {
        #expect(EditorKeyBindings.command(characters: "h", modifiers: [.command, .shift]) == .repeatLastColor)
        #expect(EditorKeyBindings.command(characters: "H", modifiers: [.command, .shift]) == .repeatLastColor)
        #expect(EditorKeyBindings.command(characters: "h", modifiers: .command) == nil)
    }

    // MARK: Выделение

    @Test("Цвет текста ставится на выделение")
    func textColorOnSelection() throws {
        let editor = try editor([.paragraph("Привет, мир!")])
        editor.select(inBlock: 0, "мир")
        editor.perform(.applyColor(text(.red)))
        #expect(editor.document.blocks[0].text == InlineText("Привет, мир!", runs: [run(8, 3, .textColor(.red))]))
    }

    @Test("Цвет фона ставится рядом с цветом текста, не вместо него")
    func backgroundAlongsideText() throws {
        let editor = try editor([.paragraph("слово")])
        editor.select(inBlock: 0, "слово")
        editor.perform(.applyColor(text(.red)))
        editor.perform(.applyColor(background(.yellow)))
        #expect(editor.document.blocks[0].text.runs == [run(0, 5, .textColor(.red)), run(0, 5, .backgroundColor(.yellow))])
    }

    @Test("Другой цвет заменяет прежний того же вида")
    func newColorReplacesOld() throws {
        let editor = try editor([.paragraph("слово")])
        editor.select(inBlock: 0, "слово")
        editor.perform(.applyColor(text(.red)))
        editor.perform(.applyColor(text(.blue)))
        #expect(editor.document.blocks[0].text.runs == [run(0, 5, .textColor(.blue))])
    }

    @Test("Тот же цвет у всего выделения снимает его")
    func sameColorTogglesOff() throws {
        let editor = try editor([.paragraph("слово")])
        editor.select(inBlock: 0, "слово")
        editor.perform(.applyColor(text(.red)))
        editor.perform(.applyColor(text(.red)))
        #expect(editor.document.blocks[0].text.runs.isEmpty)
    }

    @Test("Выделение, окрашенное лишь частично, красится целиком")
    func partialSelectionBecomesColored() throws {
        let editor = try editor([.paragraph("один два")])
        editor.select(inBlock: 0, "один")
        editor.perform(.applyColor(text(.red)))
        editor.select(inBlock: 0, "один два")
        editor.perform(.applyColor(text(.red)))
        #expect(editor.document.blocks[0].text.runs == [run(0, 8, .textColor(.red))])
    }

    @Test("«По умолчанию» снимает цвет своего вида и не трогает другой")
    func defaultClearsOnlyItsKind() throws {
        let editor = try editor([.paragraph("слово")])
        editor.select(inBlock: 0, "слово")
        editor.perform(.applyColor(text(.red)))
        editor.perform(.applyColor(background(.yellow)))
        editor.perform(.applyColor(text(nil)))
        #expect(editor.document.blocks[0].text.runs == [run(0, 5, .backgroundColor(.yellow))])
    }

    @Test("Цвет не трогает остальное оформление")
    func keepsOtherStyles() throws {
        let editor = try editor([.paragraph("жирный текст")])
        editor.select(inBlock: 0, "жирный")
        editor.perform(.toggleInline(.bold))
        editor.select(inBlock: 0, "жирный текст")
        editor.perform(.applyColor(text(.green)))
        #expect(Set(editor.document.blocks[0].text.runs) == [run(0, 6, .bold), run(0, 12, .textColor(.green))])
    }

    @Test("Цвет через несколько блоков — одним шагом отмены")
    func acrossBlocksAndUndo() throws {
        let editor = try editor([.paragraph("один"), .heading(1, "два")])
        editor.textView.setSelectedRange(NSRange(location: 2, length: 5))
        editor.perform(.applyColor(background(.pink)))
        #expect(editor.document.blocks[0].text.runs == [run(2, 2, .backgroundColor(.pink))])
        #expect(editor.document.blocks[1].text.runs == [run(0, 2, .backgroundColor(.pink))])
        editor.undo()
        #expect(editor.document.blocks.allSatisfy { $0.text.runs.isEmpty })
        editor.redo()
        #expect(editor.document.blocks[1].text.runs == [run(0, 2, .backgroundColor(.pink))])
    }

    // MARK: Без выделения

    @Test("Без выделения цвет достаётся набираемому тексту")
    func colorAffectsTyping() throws {
        let editor = try editor([.paragraph("ab")])
        editor.placeCaret(inBlock: 0, at: 1)
        editor.perform(.applyColor(text(.orange)))
        editor.type("Ж")
        #expect(editor.document.blocks[0].text == InlineText("aЖb", runs: [run(1, 1, .textColor(.orange))]))
    }

    // MARK: Вид на странице

    @Test("Цвета на странице — цвета палитры Notion: текст красится, фон подкладывается")
    func rendering() throws {
        let editor = try editor([.paragraph("один два")])
        editor.select(inBlock: 0, "два")
        editor.perform(.applyColor(text(.red)))
        editor.perform(.applyColor(background(.yellow)))
        let storage = try #require(editor.textView.textStorage)
        let colored = editor.textLocation(ofBlock: 0) + 5
        #expect(storage.attribute(.foregroundColor, at: colored, effectiveRange: nil) as? NSColor == Palette.notionText(.red))
        #expect(storage.attribute(.backgroundColor, at: colored, effectiveRange: nil) as? NSColor == Palette.notionBackground(.yellow))
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Palette.textPrimary)
        #expect(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
    }

    @Test("Цвет сохраняется и возвращается из базы")
    func survivesSaveAndReopen() throws {
        let editor = try editor([.paragraph("слово")])
        editor.select(inBlock: 0, "слово")
        editor.perform(.applyColor(text(.purple)))
        let saved = try editor.savedBlocks()
        #expect(saved[0].text.runs == [run(0, 5, .textColor(.purple))])
    }

    // MARK: Последние цвета и повтор

    @Test("Применённые цвета запоминаются: свежий сверху, без повторов, не больше пяти")
    func recentColors() throws {
        let editor = try editor([.paragraph("слово")])
        editor.select(inBlock: 0, "слово")
        let sequence = [text(.red), background(.yellow), text(.blue), text(.green), background(.pink), text(.gray), text(.red)]
        for choice in sequence { editor.perform(.applyColor(choice)) }
        let recent = editor.textView.recentColors.choices
        #expect(recent.count == 5)
        #expect(recent.first == text(.red))
        #expect(Set(recent).count == 5)
    }

    @Test("Последние цвета переживают перезапуск: пишутся в настройки и читаются из них")
    func recentColorsPersist() throws {
        let suite = "mynotion.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = RecentColors(defaults: defaults)
        first.record(text(.red))
        first.record(background(.blue))
        #expect(RecentColors(defaults: defaults).choices == [background(.blue), text(.red)])
    }

    @Test("⌘⇧H накладывает последний цвет на новое выделение, даже если на нём такой уже есть")
    func repeatLastColor() throws {
        let editor = try editor([.paragraph("один два три")])
        editor.select(inBlock: 0, "один")
        editor.perform(.applyColor(text(.red)))
        editor.select(inBlock: 0, "два")
        editor.perform(.repeatLastColor)
        #expect(editor.document.blocks[0].text.runs == [run(0, 4, .textColor(.red)), run(5, 3, .textColor(.red))])
        editor.perform(.repeatLastColor)
        #expect(editor.document.blocks[0].text.runs == [run(0, 4, .textColor(.red)), run(5, 3, .textColor(.red))], "Повтор не снимает цвет")
    }

    @Test("Повтор без последнего цвета ничего не делает")
    func repeatWithoutHistory() throws {
        let editor = try editor([.paragraph("слово")])
        editor.select(inBlock: 0, "слово")
        editor.perform(.repeatLastColor)
        #expect(editor.document.blocks[0].text.runs.isEmpty)
    }
}
