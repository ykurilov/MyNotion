import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Цвет блока целиком (FR-112): текст и подложка во всю ширину блока.
@MainActor
@Suite("Цвет блока")
struct BlockColorTests {
    private func editor(_ specs: [EditorFixture.Spec]) throws -> EditorFixture {
        let editor = try EditorFixture(specs)
        editor.textView.recentColors = RecentColors(defaults: nil)
        return editor
    }

    private func text(_ color: NotionColor?) -> ColorChoice { ColorChoice(target: .text, color: color) }
    private func background(_ color: NotionColor?) -> ColorChoice { ColorChoice(target: .background, color: color) }

    @Test("Цвет текста блока: блок хранит цвет, весь его текст на странице окрашен")
    func blockTextColor() throws {
        let editor = try editor([.paragraph("один"), .paragraph("два")])
        editor.placeCaret(inBlock: 1, at: 1)
        editor.perform(.applyBlockColor(text(.red)))
        #expect(editor.document.blocks.map(\.color) == [.none, BlockColor(text: .red)])
        let storage = try #require(editor.textView.textStorage)
        #expect(storage.attribute(.foregroundColor, at: editor.textLocation(ofBlock: 1), effectiveRange: nil) as? NSColor == Palette.notionText(.red))
        #expect(storage.attribute(.foregroundColor, at: editor.textLocation(ofBlock: 0), effectiveRange: nil) as? NSColor == Palette.textPrimary)
    }

    @Test("Фон блока хранится в блоке и не красит текст")
    func blockBackground() throws {
        let editor = try editor([.paragraph("один")])
        editor.perform(.applyBlockColor(background(.yellow)))
        #expect(editor.document.blocks[0].color == BlockColor(background: .yellow))
        let storage = try #require(editor.textView.textStorage)
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Palette.textPrimary)
    }

    @Test("Оба цвета вместе; тот же цвет снимает свой вид, «По умолчанию» тоже")
    func combineAndClear() throws {
        let editor = try editor([.paragraph("один")])
        editor.perform(.applyBlockColor(text(.blue)))
        editor.perform(.applyBlockColor(background(.pink)))
        #expect(editor.document.blocks[0].color == BlockColor(text: .blue, background: .pink))
        editor.perform(.applyBlockColor(text(.blue)))
        #expect(editor.document.blocks[0].color == BlockColor(background: .pink))
        editor.perform(.applyBlockColor(background(nil)))
        #expect(editor.document.blocks[0].color == .none)
    }

    @Test("Выделенные через несколько блоков красятся все, отмена — одним шагом")
    func severalBlocksAndUndo() throws {
        let editor = try editor([.paragraph("раз"), .heading(2, "два"), .paragraph("три")])
        editor.textView.selectBlocks(0..<2)
        editor.perform(.applyBlockColor(background(.green)))
        #expect(editor.document.blocks.map(\.color) == [BlockColor(background: .green), BlockColor(background: .green), .none])
        editor.undo()
        #expect(editor.document.blocks.allSatisfy { $0.color.isNone })
    }

    @Test("Цвет блока переживает правку текста и сохранение")
    func survivesEditsAndSave() throws {
        let editor = try editor([.paragraph("один")])
        editor.perform(.applyBlockColor(text(.orange)))
        editor.placeCaret(inBlock: 0, at: nil)
        editor.type("!")
        #expect(editor.document.blocks[0].color == BlockColor(text: .orange))
        #expect(try editor.savedBlocks()[0].color == BlockColor(text: .orange))
    }

    @Test("Цвет блока записан на странице и у нового абзаца после Enter не наследуется")
    func newBlockAfterEnterIsPlain() throws {
        let editor = try editor([.paragraph("один")])
        editor.perform(.applyBlockColor(background(.gray)))
        editor.placeCaret(inBlock: 0, at: nil)
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(editor.document.blocks.count == 2)
        #expect(editor.document.blocks[1].color.isNone)
    }

    @Test("Цвет текста в строке сильнее цвета блока")
    func inlineBeatsBlock() throws {
        let editor = try editor([.paragraph("один два")])
        editor.perform(.applyBlockColor(text(.gray)))
        editor.select(inBlock: 0, "два")
        editor.perform(.applyColor(text(.red)))
        let storage = try #require(editor.textView.textStorage)
        #expect(storage.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor == Palette.notionText(.red))
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Palette.notionText(.gray))
    }

    // MARK: Подложка

    @Test("Подложка: цвет палитры, во всю ширину блока, скругление 4; без цвета фона подложки нет")
    func backgroundPainter() {
        let rect = CGRect(x: 100, y: 20, width: 700, height: 32)
        let painted = BlockBackgroundPainter.shape(for: BlockColor(background: .yellow), in: rect)
        #expect(painted?.rect == rect)
        #expect(painted?.cornerRadius == 4)
        #expect(painted?.fill == Palette.notionBackground(.yellow))
        #expect(BlockBackgroundPainter.shape(for: BlockColor(text: .red), in: rect) == nil)
        #expect(BlockBackgroundPainter.shape(for: .none, in: rect) == nil)
    }

    @Test("Подложка входит в общие рисователи, слой — под текстом")
    func painterRegistered() {
        let painter = BlockPainters.common.first { $0 is BlockBackgroundPainter }
        #expect(painter?.layer == .background)
    }
}
