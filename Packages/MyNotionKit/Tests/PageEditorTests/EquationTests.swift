import AppKit
import Testing
@testable import MathRendering
@testable import NotesCore
@testable import PageEditor

/// Формулы (FR-105, contracts/blocks-and-keys.md, «Формула»): блок и в строке, окно правки — Enter готово,
/// ⇧Enter новая строка записи, Esc отмена; пустая — «Новая формула», ошибка — «Неверная формула».
@MainActor
@Suite("Формулы в редакторе", .serialized)
struct EquationTests {
    typealias Spec = EditorFixture.Spec

    func editor(_ fixture: EditorFixture) -> EquationEditorController { fixture.textView.equationEditor }

    func setField(_ text: String, _ fixture: EditorFixture) {
        let field = editor(fixture).field
        field.string = text
        field.didChangeText()
    }

    func equationView(_ fixture: EditorFixture, block index: Int) throws -> EquationBlockView {
        let block = fixture.document.blocks[index]
        let factory = try #require(BlockViewFactories.shared.factory(for: .equation))
        return try #require(factory.makeView(for: block, context: BlockViewContext(textView: fixture.textView, width: 720)) as? EquationBlockView)
    }

    var equationRuns: (InlineText) -> [String] {
        { text in text.runs.compactMap { if case .equation(let latex) = $0.style { latex } else { nil } } }
    }

    @Test("«$$» и пробел — формула-блок, открыто окно правки; Enter — готово, ⌘Z — назад")
    func dollarShortcut() throws {
        let fixture = try EditorFixture([.paragraph()])
        fixture.type("$$ ")
        #expect(fixture.kinds == [.equation])
        #expect(editor(fixture).isOpen)
        #expect(editor(fixture).target == .block(fixture.document.blocks[0].id))
        setField("E = mc^2", fixture)
        #expect(editor(fixture).previewIsRendered)
        fixture.step { editor(fixture).field.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        #expect(!editor(fixture).isOpen)
        #expect(fixture.texts == ["E = mc^2"])
        fixture.undo()
        #expect(fixture.texts == [""])
        #expect(fixture.kinds == [.equation])
    }

    @Test("«/» → «Формула» открывает окно; ⇧Enter — новая строка записи; Esc — правка отменена")
    func slashAndKeys() throws {
        let fixture = try EditorFixture([Spec(kind: .equation, text: "a"), .paragraph("x")])
        fixture.placeCaret(inBlock: 1)
        fixture.perform(.setKind(.equation))
        #expect(fixture.kinds == [.equation, .equation])
        #expect(editor(fixture).target == .block(fixture.document.blocks[1].id))
        fixture.step { editor(fixture).cancel() }
        fixture.textView.openEquationEditor(forBlock: fixture.document.blocks[0].id)
        #expect(editor(fixture).field.string == "a")
        editor(fixture).field.setSelectedRange(NSRange(location: 1, length: 0))
        editor(fixture).field.doCommand(by: #selector(NSResponder.insertLineBreak(_:)))
        #expect(editor(fixture).field.string == "a\n")
        #expect(editor(fixture).isOpen)
        setField("b", fixture)
        fixture.step { editor(fixture).field.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
        #expect(!editor(fixture).isOpen)
        #expect(fixture.texts[0] == "a")
    }

    @Test("Вид блока: формула картинкой; пустая — «Новая формула»; ошибка — «Неверная формула», запись цела")
    func blockView() throws {
        let fixture = try EditorFixture([Spec(kind: .equation, text: "\\frac{1}{2}"), Spec(kind: .equation), Spec(kind: .equation, text: "\\frac{")])
        let valid = try equationView(fixture, block: 0)
        #expect(valid.message == nil)
        #expect(valid.formulaImage != nil)
        #expect(try equationView(fixture, block: 1).message == FormulaImageCache.emptyFormulaText)
        #expect(try equationView(fixture, block: 2).message == FormulaImageCache.invalidFormulaText)
        #expect(fixture.texts[2] == "\\frac{")
        let factory = try #require(BlockViewFactories.shared.factory(for: .equation))
        #expect((factory.height(for: fixture.document.blocks[0], width: 720) ?? 0) > (factory.height(for: fixture.document.blocks[1], width: 720) ?? 0))
    }

    @Test("⌃⇧E: выделенный текст становится формулой в строке; ⌘Z — текст назад")
    func inlineFromSelection() throws {
        #expect(EditorKeyBindings.command(characters: "e", modifiers: [.control, .shift]) == .insertInlineEquation)
        #expect(FormatBarButton.allCases.contains(.equation))
        let fixture = try EditorFixture([.paragraph("Площадь x^2 круга")])
        fixture.select(inBlock: 0, "x^2")
        fixture.perform(.insertInlineEquation)
        let text = fixture.document.blocks[0].text
        #expect(text.string == "Площадь \u{FFFC} круга")
        #expect(equationRuns(text) == ["x^2"])
        #expect(!editor(fixture).isOpen)
        fixture.undo()
        #expect(fixture.texts == ["Площадь x^2 круга"])
    }

    @Test("⌃⇧E без выделения — новая формула в строке и окно правки; щелчок по формуле — правка записи")
    func inlineEmptyAndEdit() throws {
        let fixture = try EditorFixture([.paragraph("Итог: ")])
        fixture.placeCaret(inBlock: 0, at: nil)
        fixture.perform(.insertInlineEquation)
        #expect(editor(fixture).isOpen)
        guard case .inline(let blockId, let location)? = editor(fixture).target else {
            Issue.record("Окно не для формулы в строке")
            return
        }
        #expect(blockId == fixture.document.blocks[0].id)
        #expect(location == 6)
        setField("\\sqrt{2}", fixture)
        fixture.step { editor(fixture).field.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        #expect(equationRuns(fixture.document.blocks[0].text) == ["\\sqrt{2}"])
        #expect(fixture.document.blocks[0].text.string == "Итог: \u{FFFC}")

        #expect(fixture.textView.openAtom(atCharacter: 6))
        #expect(editor(fixture).field.string == "\\sqrt{2}")
        // Запись в строке однострочная: ⇧Enter — тоже «готово».
        setField("\\sqrt{3}", fixture)
        fixture.step { editor(fixture).field.doCommand(by: #selector(NSResponder.insertLineBreak(_:))) }
        #expect(equationRuns(fixture.document.blocks[0].text) == ["\\sqrt{3}"])
        fixture.undo()
        #expect(equationRuns(fixture.document.blocks[0].text) == ["\\sqrt{2}"])
    }

    @Test("Формула в строке рисуется картинкой; при копировании — её запись")
    func inlineAttachment() throws {
        let fixture = try EditorFixture([.paragraph("a b")])
        fixture.select(inBlock: 0, "b")
        fixture.step { fixture.textView.insertAtom(.equation("\\alpha"), in: fixture.textView.selectedRange(), blockAt: 0) }
        let attachment = try #require(fixture.textView.atomAttachment(at: 2) as? InlineEquationAttachment)
        #expect(attachment.size(in: fixture.textView).width > 4)
        #expect(fixture.textView.plainText(of: NSRange(location: 0, length: 3)) == "a \\alpha")
    }
}
