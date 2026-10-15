import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Подчёркнутый — стиль в строке, как у Notion (FR-033): хранится в том же поле оформления, рисуется линией
/// цвета текста, ⌘U ставит и снимает, вставка из других программ его сохраняет.
@MainActor
@Suite("Подчёркнутый")
struct UnderlineStyleTests {
    @Test("Хранится словом «underline» в той же записи отрезков и читается обратно")
    func storedInSameField() throws {
        let text = InlineText("один два", runs: [StyledRun(start: 5, length: 3, style: .underline)])
        let json = try #require(String(data: JSONEncoder().encode(text), encoding: .utf8))
        #expect(json.contains("\"underline\""), "Запись: \(json)")
        #expect(try JSONDecoder().decode(InlineText.self, from: Data(json.utf8)) == text)
    }

    @Test("Единая запись: подчёркнутый после кода, ссылка — последней")
    func normalizedOrder() {
        let url = URL(string: "https://kurilov.cloud")!
        let text = InlineText("abc", runs: [
            StyledRun(start: 0, length: 3, style: .link(url)),
            StyledRun(start: 0, length: 3, style: .underline),
            StyledRun(start: 0, length: 3, style: .code),
            StyledRun(start: 0, length: 1, style: .underline),
        ]).normalized()
        #expect(text.runs.map(\.style) == [.code, .underline, .link(url)])
        #expect(text.runs[1].length == 3, "Отрезки подчёркнутого слиты")
    }

    @Test("⌘U — подчёркнутый, и в русской раскладке")
    func keyBinding() {
        #expect(EditorKeyBindings.command(characters: "u", modifiers: .command) == .toggleInline(.underline))
        #expect(EditorKeyBindings.command(characters: "U", modifiers: .command) == .toggleInline(.underline))
        #expect(EditorKeyBindings.command(characters: "u", modifiers: [.command, .shift]) == nil)
        #expect(InlineFormat.underline.style == .underline)
    }

    @Test("Ставится и снимается на выделении, переживает перевод в текст страницы и обратно")
    func toggleAndRoundTrip() throws {
        let editor = try EditorFixture([.paragraph("Привет, мир!")])
        editor.select(inBlock: 0, "мир")

        editor.perform(.toggleInline(.underline))
        let underlined = InlineText("Привет, мир!", runs: [StyledRun(start: 8, length: 3, style: .underline)])
        #expect(editor.document.blocks[0].text == underlined)
        let drafts = PageTextStorageMapper.blockDrafts(in: PageTextStorageMapper.attributedText(for: editor.document.blocks))
        #expect(drafts.first?.text == underlined)

        editor.perform(.toggleInline(.underline))
        #expect(editor.document.blocks[0].text == InlineText("Привет, мир!"))
    }

    @Test("Рисуется линией цвета текста; у подчёркнутой ссылки линия тоже цвета текста, а не серая")
    func rendering() throws {
        let url = URL(string: "https://kurilov.cloud")!
        let block = Block(pageId: UUID(), kind: .paragraph, text: InlineText("раз два три", runs: [
            StyledRun(start: 0, length: 3, style: .underline),
            StyledRun(start: 4, length: 3, style: .link(url)),
            StyledRun(start: 8, length: 3, style: .link(url)),
            StyledRun(start: 8, length: 3, style: .underline),
        ]), sortKey: .between(nil, nil))
        let text = PageTextStorageMapper.attributedText(for: [block])
        func attribute(_ key: NSAttributedString.Key, at index: Int) -> Any? { text.attribute(key, at: index, effectiveRange: nil) }

        #expect(attribute(.underlineStyle, at: 1) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(attribute(.underlineColor, at: 1) == nil, "Линия подчёркнутого — цвета текста")
        #expect(attribute(.underlineStyle, at: 3) == nil, "Пробел после слова не подчёркнут")
        #expect(attribute(.underlineColor, at: 5) as? NSColor == Palette.linkUnderline, "Простая ссылка — серая линия")
        #expect(attribute(.underlineStyle, at: 9) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(attribute(.underlineColor, at: 9) == nil, "Подчёркнутая ссылка — линия цвета текста")
    }

    @Test("Без выделения ⌘U подчёркивает набираемый текст")
    func typingStyle() throws {
        let editor = try EditorFixture([.paragraph("ab")])
        editor.placeCaret(inBlock: 0, at: 1)

        editor.perform(.toggleInline(.underline))
        editor.type("Ж")

        #expect(editor.document.blocks[0].text == InlineText("aЖb", runs: [StyledRun(start: 1, length: 1, style: .underline)]))
    }

    @Test("Вставка из другого приложения сохраняет подчёркивание")
    func pasteKeepsUnderline() throws {
        let editor = try EditorFixture([.paragraph("")])
        editor.placeCaret(inBlock: 0, at: 0)
        let rich = NSMutableAttributedString(string: "просто ")
        rich.append(NSAttributedString(string: "черта", attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]))
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MyNotionTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setString(rich.string, forType: .string)

        editor.step { editor.textView.paste(from: pasteboard) }

        #expect(editor.document.blocks[0].text == InlineText("просто черта", runs: [StyledRun(start: 7, length: 5, style: .underline)]))
    }
}
