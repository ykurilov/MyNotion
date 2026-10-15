import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor

/// Оформление в строке, ссылки и вставка (FR-010; contracts/editor-interactions.md, «Клавиши»).
@MainActor
@Suite("Оформление в строке")
struct InlineStyleTests {
    @Test("⌘B, ⌘I, ⇧⌘X, ⌘E — жирный, курсив, зачёркнутый, код; ⌘K свободна")
    func keyBindings() {
        #expect(EditorKeyBindings.command(characters: "b", modifiers: .command) == .toggleInline(.bold))
        #expect(EditorKeyBindings.command(characters: "i", modifiers: .command) == .toggleInline(.italic))
        #expect(EditorKeyBindings.command(characters: "x", modifiers: [.command, .shift]) == .toggleInline(.strikethrough))
        #expect(EditorKeyBindings.command(characters: "X", modifiers: [.command, .shift]) == .toggleInline(.strikethrough))
        #expect(EditorKeyBindings.command(characters: "e", modifiers: .command) == .toggleInline(.code))
        #expect(EditorKeyBindings.command(characters: "x", modifiers: .command) == nil, "⌘X — вырезать")
        #expect(EditorKeyBindings.command(characters: "k", modifiers: .command) == nil)
        #expect(EditorKeyBindings.command(characters: "б", modifiers: .command) == nil)
    }

    @Test("Оформление выделения ставится и снимается", arguments: [
        (InlineFormat.bold, InlineStyle.bold), (.italic, .italic), (.strikethrough, .strikethrough), (.code, .code),
    ])
    func toggleOnSelection(format: InlineFormat, style: InlineStyle) throws {
        let editor = try EditorFixture([.paragraph("Привет, мир!")])
        editor.select(inBlock: 0, "мир")

        editor.perform(.toggleInline(format))
        #expect(editor.document.blocks[0].text == InlineText("Привет, мир!", runs: [StyledRun(start: 8, length: 3, style: style)]))

        editor.perform(.toggleInline(format))
        #expect(editor.document.blocks[0].text == InlineText("Привет, мир!"))
    }

    @Test("Частично жирное выделение становится жирным целиком")
    func partialSelectionBecomesBold() throws {
        let editor = try EditorFixture([.paragraph("один два")])
        editor.select(inBlock: 0, "два")
        editor.perform(.toggleInline(.bold))
        editor.select(inBlock: 0, "один два")

        editor.perform(.toggleInline(.bold))

        #expect(editor.document.blocks[0].text.runs == [StyledRun(start: 0, length: 8, style: .bold)])
    }

    @Test("Без выделения ⌘B включает жирный для набираемого текста")
    func toggleWithoutSelectionAffectsTyping() throws {
        let editor = try EditorFixture([.paragraph("ab")])
        editor.placeCaret(inBlock: 0, at: 1)

        editor.perform(.toggleInline(.bold))
        editor.type("Ж")

        #expect(editor.document.blocks[0].text == InlineText("aЖb", runs: [StyledRun(start: 1, length: 1, style: .bold)]))
    }

    @Test("Оформление через несколько блоков и его отмена")
    func toggleAcrossBlocksAndUndo() throws {
        let editor = try EditorFixture([.paragraph("один"), .heading(1, "два")])
        editor.textView.setSelectedRange(NSRange(location: 2, length: 5))

        editor.perform(.toggleInline(.italic))
        #expect(editor.document.blocks[0].text.runs == [StyledRun(start: 2, length: 2, style: .italic)])
        #expect(editor.document.blocks[1].text.runs == [StyledRun(start: 0, length: 2, style: .italic)])
        #expect(editor.kinds == [.paragraph, .heading1])

        editor.undo()
        #expect(editor.document.blocks.allSatisfy { $0.text.runs.isEmpty })
    }

    // MARK: Ссылки

    @Test("Вставка адреса поверх выделения делает выделение ссылкой")
    func pastingURLOverSelectionCreatesLink() throws {
        let editor = try EditorFixture([.paragraph("Смотри сайт тут")])
        editor.select(inBlock: 0, "сайт")
        let pasteboard = Self.pasteboard { $0.setString("https://kurilov.cloud/notes", forType: .string) }

        editor.step { editor.textView.paste(from: pasteboard) }

        let url = try #require(URL(string: "https://kurilov.cloud/notes"))
        #expect(editor.document.blocks[0].text == InlineText("Смотри сайт тут", runs: [StyledRun(start: 7, length: 4, style: .link(url))]))
        editor.undo()
        #expect(editor.document.blocks[0].text == InlineText("Смотри сайт тут"))
    }

    @Test("Адрес без выделения вставляется текстом")
    func pastingURLWithoutSelectionInsertsText() throws {
        let editor = try EditorFixture([.paragraph("см. ")])
        editor.placeCaret(inBlock: 0, at: nil)
        let pasteboard = Self.pasteboard { $0.setString("https://kurilov.cloud", forType: .string) }

        editor.step { editor.textView.paste(from: pasteboard) }

        #expect(editor.document.blocks[0].text == InlineText("см. https://kurilov.cloud"))
    }

    @Test("Обычный текст поверх выделения заменяет его")
    func pastingTextOverSelectionReplaces() throws {
        let editor = try EditorFixture([.paragraph("один два")])
        editor.select(inBlock: 0, "два")
        let pasteboard = Self.pasteboard { $0.setString("три четыре", forType: .string) }

        editor.step { editor.textView.paste(from: pasteboard) }

        #expect(editor.texts == ["один три четыре"])
    }

    @Test("«Формат → Ссылка» ставит и снимает ссылку на выделении")
    func linkFromMenu() throws {
        let editor = try EditorFixture([.paragraph("Ссылка здесь")])
        editor.select(inBlock: 0, "здесь")
        let url = try #require(URL(string: "https://www.notion.so"))

        editor.step { editor.textView.setLink(url) }
        #expect(editor.document.blocks[0].text.runs == [StyledRun(start: 7, length: 5, style: .link(url))])

        editor.step { editor.textView.setLink(nil) }
        #expect(editor.document.blocks[0].text.runs.isEmpty)
    }

    @Test("Адрес для ссылки: только http, https и mailto; без схемы — https")
    func linkAddressParsing() {
        #expect(InlineFormatting.linkURL(from: " https://kurilov.cloud ") == URL(string: "https://kurilov.cloud"))
        #expect(InlineFormatting.linkURL(from: "mailto:yury@example.com") == URL(string: "mailto:yury@example.com"))
        #expect(InlineFormatting.linkURL(from: "kurilov.cloud/x") == URL(string: "https://kurilov.cloud/x"))
        #expect(InlineFormatting.linkURL(from: "просто текст") == nil)
        #expect(InlineFormatting.linkURL(from: "javascript:alert(1)") == nil)
        #expect(InlineFormatting.pastedLinkURL(from: "два слова https://a.b") == nil, "Вставка ссылкой — только чистый адрес")
    }

    // MARK: Вставка из других программ

    @Test("Вставка из другого приложения оставляет текст и поддерживаемое оформление")
    func pastingRichTextKeepsSupportedStyles() throws {
        let editor = try EditorFixture([.paragraph("Начало: "), .paragraph("конец")])
        editor.placeCaret(inBlock: 0, at: nil)
        let rich = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Times New Roman", size: 31) ?? NSFont.systemFont(ofSize: 31),
                                                   .foregroundColor: NSColor.red]
        rich.append(NSAttributedString(string: "жирный", attributes: base.merging([.font: NSFont.boldSystemFont(ofSize: 31)]) { $1 }))
        rich.append(NSAttributedString(string: " ", attributes: base))
        rich.append(NSAttributedString(string: "курсив", attributes: base.merging([
            .font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask),
        ]) { $1 }))
        rich.append(NSAttributedString(string: " ", attributes: base))
        rich.append(NSAttributedString(string: "код", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
        rich.append(NSAttributedString(string: " ", attributes: base))
        rich.append(NSAttributedString(string: "зачёркнуто", attributes: base.merging([.strikethroughStyle: NSUnderlineStyle.single.rawValue]) { $1 }))
        rich.append(NSAttributedString(string: "\nвторой ", attributes: base))
        rich.append(NSAttributedString(string: "абзац", attributes: base.merging([.link: URL(string: "https://kurilov.cloud")!]) { $1 }))
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let pasteboard = Self.pasteboard { pasteboard in
            pasteboard.setData(rtf, forType: .rtf)
            pasteboard.setString(rich.string, forType: .string)
        }

        editor.step { editor.textView.paste(from: pasteboard) }

        #expect(editor.texts == ["Начало: жирный курсив код зачёркнуто", "второй абзац", "конец"])
        #expect(editor.document.blocks[0].text.runs == [
            StyledRun(start: 8, length: 6, style: .bold),
            StyledRun(start: 15, length: 6, style: .italic),
            StyledRun(start: 22, length: 3, style: .code),
            StyledRun(start: 26, length: 10, style: .strikethrough),
        ])
        #expect(editor.document.blocks[1].text.runs == [StyledRun(start: 7, length: 5, style: .link(URL(string: "https://kurilov.cloud")!))])
        #expect(editor.kinds == [.paragraph, .paragraph, .paragraph])
        // Чужие шрифт, размер и цвет не переносятся: вид — как у остального текста страницы.
        let storage = try #require(editor.textView.textStorage)
        let font = storage.attribute(.font, at: 8 + 3, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 16)
        #expect((storage.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor) != NSColor.red)
    }

    private static func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MyNotionTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        fill(pasteboard)
        return pasteboard
    }
}
