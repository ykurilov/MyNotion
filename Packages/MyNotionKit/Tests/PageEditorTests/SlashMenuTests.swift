import AppKit
import Testing
import VisualStyle
@testable import NotesCore
@testable import PageEditor

@MainActor
@Suite("Меню «/» и меню блока")
struct SlashMenuTests {
    @Test("Поиск по названию и словам-подсказкам без учёта регистра")
    func filtersItems() {
        #expect(PopupMenuItem.slashItems(matching: "").count == PopupMenuItem.slashItems.count)
        #expect(PopupMenuItem.slashItems(matching: "Заго").map(\.action) == [.setKind(.heading1), .setKind(.heading2), .setKind(.heading3)])
        #expect(PopupMenuItem.slashItems(matching: "todo").map(\.action) == [.setKind(.checkbox)])
        #expect(PopupMenuItem.slashItems(matching: "h2").map(\.action) == [.setKind(.heading2)])
        #expect(PopupMenuItem.slashItems(matching: "нетакого").isEmpty)
    }

    @Test("«/» открывает меню, набор сужает список, Enter меняет тип и убирает набранное")
    func slashCommandChangesKind() throws {
        let editor = try EditorFixture([.paragraph("дело")])
        editor.placeCaret(inBlock: 0, at: nil)
        editor.type(" /")
        #expect(editor.textView.popups.isOpen)

        editor.type("чек")
        #expect(editor.textView.popups.visibleItems.map(\.action) == [.setKind(.checkbox)])
        editor.press(#selector(NSResponder.insertNewline(_:)))

        #expect(!editor.textView.popups.isOpen)
        #expect(editor.kinds == [.checkbox])
        #expect(editor.texts == ["дело "])
    }

    @Test("Esc закрывает меню и оставляет набранный текст")
    func escapeClosesMenu() throws {
        let editor = try EditorFixture([.paragraph()])
        editor.placeCaret(inBlock: 0)
        editor.type("/за")
        editor.press(#selector(NSResponder.cancelOperation(_:)))

        #expect(!editor.textView.popups.isOpen)
        #expect(editor.kinds == [.paragraph])
        #expect(editor.texts == ["/за"])
    }

    @Test("Стрелки выбирают пункт меню")
    func arrowsMoveSelection() throws {
        let editor = try EditorFixture([.paragraph()])
        editor.placeCaret(inBlock: 0)
        editor.type("/")
        editor.press(#selector(NSResponder.moveDown(_:)))
        editor.press(#selector(NSResponder.moveDown(_:)))
        editor.press(#selector(NSResponder.insertNewline(_:)))

        #expect(editor.kinds == [.heading2])
        #expect(editor.texts == [""])
    }
}

/// Где встаёт меню «/» и что видно в строке с «/» (contracts/visual-style.md, «Всплывающие меню»; ui-review 15.10.2026, № 5).
@MainActor
@Suite("Меню «/»: место и подсказка")
struct SlashMenuPlacementTests {
    /// Рамка знака в координатах экрана.
    static func screenRect(of range: NSRange, in editor: EditorFixture) -> NSRect {
        editor.textView.firstRect(forCharacterRange: range, actualRange: nil)
    }

    /// Строка текста целиком (высота строки блока) в координатах экрана.
    static func screenLine(ofBlock index: Int, in editor: EditorFixture) throws -> NSRect {
        let textView = editor.textView
        let line = try #require(textView.markerLine(ofBlockAt: index))
        let origin = textView.textContainerOrigin
        let inView = NSRect(x: origin.x, y: origin.y + line.top, width: Metrics.Page.columnWidth, height: line.height)
        return editor.window.convertToScreen(textView.convert(inView, to: nil))
    }

    @Test("Меню открывается от левого края «/» на 4 ниже строки и закрывает следующий абзац целиком",
          arguments: [EditorFixture.Spec.paragraph(), .paragraph("дело ")])
    func menuSitsBelowSlashLine(spec: EditorFixture.Spec) throws {
        let editor = try EditorFixture([spec, .paragraph("Абзац ниже")])
        editor.placeCaret(inBlock: 0, at: nil)
        editor.type("/")
        let slashLocation = editor.textView.selectedRange().location - 1
        let menu = try #require(editor.textView.popups.menuFrame)
        let slash = Self.screenRect(of: NSRange(location: slashLocation, length: 1), in: editor)
        let line = try Self.screenLine(ofBlock: 0, in: editor)
        let below = Self.screenRect(of: NSRange(location: editor.textLocation(ofBlock: 1), length: 1), in: editor)

        #expect(menu.minX <= slash.minX + 0.5, "Левый край меню \(menu.minX), «/» с \(slash.minX)")
        if spec.text.isEmpty {
            // «/» в начале строки: меню закрывает начало следующего абзаца целиком, огрызков букв слева нет.
            #expect(menu.minX <= below.minX + 0.5, "Левый край меню \(menu.minX), следующий абзац с \(below.minX)")
        }
        // Экранные координаты: y растёт вверх.
        #expect(abs((line.minY - menu.maxY) - Metrics.PopupMenu.anchorSpacing) < 0.5,
                "Верх меню \(menu.maxY), низ строки \(line.minY): зазор должен быть \(Metrics.PopupMenu.anchorSpacing)")
    }

    @Test("Пустая строка с «/»: подсказка «Начните вводить для поиска» сразу за «/», как «Type to search» у Notion; строка подсвечена hoverBackground")
    func slashLineShowsHint() throws {
        let editor = try EditorFixture([.paragraph("Выше"), .paragraph(), .paragraph("Ниже")])
        editor.placeCaret(inBlock: 1)
        editor.type("/")
        let textView = editor.textView
        let hint = textView.emptyParagraphHint
        let start = editor.textLocation(ofBlock: 1)
        let slash = textView.convert(editor.window.convertFromScreen(Self.screenRect(of: NSRange(location: start, length: 1), in: editor)), from: nil)

        #expect(!hint.isHidden)
        #expect(hint.stringValue == "Начните вводить для поиска")
        let hintTextStart = hint.frame.minX + PageTextView.hintLabelTextInset
        #expect(abs(hintTextStart - slash.maxX) <= 1, "Текст подсказки с \(hintTextStart), «/» до \(slash.maxX): без сдвига, как у Notion")
        let baseline = try #require(textView.markerLine(ofBlockAt: 1)).baseline + textView.textContainerOrigin.y
        #expect(abs(hint.frame.minY + hint.firstBaselineOffsetFromTop - baseline) < 0.5)
        let highlight = try #require(textView.slashQueryHighlightFrame, "Подсветки нет")
        #expect(highlight.contains(slash.insetBy(dx: 0.5, dy: 2)) && highlight.contains(hint.frame.insetBy(dx: 1, dy: 2)),
                "Подсветка \(highlight) не накрывает «/» \(slash) и подсказку \(hint.frame)")

        editor.type("з")
        #expect(hint.isHidden, "С набранным поиском подсказки нет")
        let typed = textView.convert(editor.window.convertFromScreen(Self.screenRect(of: NSRange(location: start, length: 2), in: editor)), from: nil)
        let grown = try #require(textView.slashQueryHighlightFrame)
        #expect(grown.contains(typed.insetBy(dx: 0.5, dy: 2)), "Подсветка \(grown), набрано \(typed)")

        editor.press(#selector(NSResponder.cancelOperation(_:)))
        #expect(textView.slashQueryHighlightFrame == nil, "Меню закрыто — подсветки нет")
    }
}
