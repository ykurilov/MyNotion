import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// Блок кода (research R5, «Решение 19.10.2026»): на странице — абзац-вложение, в его виде — свой редактор, где строка
/// кода — свой абзац. Код пишется в `text` блока (строки через `\n`), отменяется общим ⌘Z окна.
/// Виды вложений TextKit создаёт только в видимом окне, поэтому вид блока здесь создаёт тест — той же фабрикой.
@MainActor
@Suite("Блок кода", .serialized)
struct CodeBlockEditingTests {
    typealias Spec = EditorFixture.Spec

    init() {
        UserDefaults.standard.removeObject(forKey: CodeLanguageMemory.defaultsKey)
    }

    static func code(_ text: String) -> Spec { Spec(kind: .code, text: text) }

    /// Вид блока кода `index`, как его создаёт TextKit для видимой строки.
    func codeView(_ fixture: EditorFixture, block index: Int) throws -> CodeBlockView {
        let block = fixture.document.blocks[index]
        if let existing = fixture.textView.codeBlocks.view(for: block.id) { return existing }
        let factory = try #require(BlockViewFactories.shared.factory(for: .code))
        let view = try #require(factory.makeView(for: block, context: BlockViewContext(textView: fixture.textView, width: 720)) as? CodeBlockView)
        view.frame = NSRect(x: 0, y: 0, width: 720, height: factory.height(for: block, width: 720) ?? 100)
        fixture.textView.addSubview(view)
        return view
    }

    /// Набор посимвольно. Набор подряд — один шаг отмены: в приложении группа отмены открывается только при записи
    /// шага, а здесь у каждого шага своя, поэтому серия идёт одним шагом теста.
    func type(_ text: String, in view: CodeBlockView, _ fixture: EditorFixture) {
        fixture.step {
            for character in text {
                view.textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
    }

    func press(_ selector: Selector, in view: CodeBlockView, _ fixture: EditorFixture) {
        fixture.step { view.textView.doCommand(by: selector) }
    }

    var firstResponder: (EditorFixture) -> NSResponder? { { $0.window.firstResponder } }

    // MARK: Создание

    @Test("``` в пустом абзаце — блок кода, курсор в его редакторе; язык — «Простой текст»")
    func backticksCreateCode() throws {
        let fixture = try EditorFixture([.paragraph("До"), .paragraph()])
        fixture.placeCaret(inBlock: 1)
        fixture.type("```")
        #expect(fixture.kinds == [.paragraph, .code])
        #expect(fixture.document.blocks[1].text == .empty)
        #expect(fixture.document.blocks[1].props.language == "plain")
        #expect(fixture.textView.string == "До\n\u{FFFC}\n")
        let view = try codeView(fixture, block: 1)
        #expect(firstResponder(fixture) === view.textView)
        #expect(view.textView.selectedRange() == NSRange(location: 0, length: 0))
        // ⌘Z — снова абзац.
        fixture.undo()
        #expect(fixture.kinds == [.paragraph, .paragraph])
    }

    @Test("Новый блок кода берёт последний выбранный язык")
    func lastLanguage() throws {
        let fixture = try EditorFixture([Self.code("x"), .paragraph()])
        let view = try codeView(fixture, block: 0)
        fixture.step { view.setLanguage("python") }
        #expect(fixture.document.blocks[0].props.language == "python")
        #expect(view.languageButton.title.hasPrefix("Python"))
        fixture.undo()
        #expect(fixture.document.blocks[0].props.language ?? "plain" == "plain")
        fixture.redo()
        fixture.placeCaret(inBlock: 1)
        fixture.type("```")
        #expect(fixture.document.blocks[1].props.language == "python")
    }

    @Test("«/» → «Код»: текст абзаца становится кодом, курсор в его конце")
    func slashCode() throws {
        let fixture = try EditorFixture([.paragraph("let a = 1")])
        fixture.placeCaret(inBlock: 0, at: nil)
        fixture.perform(.setKind(.code))
        #expect(fixture.kinds == [.code])
        #expect(fixture.texts == ["let a = 1"])
        let view = try codeView(fixture, block: 0)
        #expect(firstResponder(fixture) === view.textView)
        #expect(view.textView.selectedRange().location == 9)
    }

    // MARK: Правка

    @Test("Правка в редакторе пишет text блока строками через \\n и отменяется общим ⌘Z")
    func editingWritesDocument() throws {
        let fixture = try EditorFixture([.paragraph("До"), Self.code(""), .paragraph("После")])
        let view = try codeView(fixture, block: 1)
        view.textView.window?.makeFirstResponder(view.textView)
        fixture.step {
            for character in "let a" { view.textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            view.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            view.textView.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(fixture.document.blocks[1].text.string == "let a\nb")
        #expect(fixture.textView.string == "До\n\u{FFFC}\nПосле\n", "текст страницы не меняется")
        #expect(try fixture.savedBlocks()[1].text.string == "let a\nb")
        fixture.undo()
        #expect(fixture.document.blocks[1].text.string == "")
        #expect(view.textView.string == "")
        fixture.redo()
        #expect(fixture.document.blocks[1].text.string == "let a\nb")
        #expect(view.textView.string == "let a\nb")
    }

    @Test("Отмена кода и правок страницы — одна цепочка по порядку")
    func undoChainWithPage() throws {
        let fixture = try EditorFixture([.paragraph("А"), Self.code("x")])
        fixture.placeCaret(inBlock: 0, at: nil)
        fixture.type("Б")
        let view = try codeView(fixture, block: 1)
        view.textView.window?.makeFirstResponder(view.textView)
        view.textView.setSelectedRange(NSRange(location: 1, length: 0))
        type("y", in: view, fixture)
        #expect(fixture.texts == ["АБ", "xy"])
        fixture.undo()
        #expect(fixture.texts == ["АБ", "x"])
        fixture.undo()
        #expect(fixture.texts == ["А", "x"])
    }

    @Test("Enter — строка внутри с отступом строки; ⌘Enter — абзац под блоком")
    func enterAndCommandEnter() throws {
        let fixture = try EditorFixture([Self.code("    x"), .paragraph("После")])
        let view = try codeView(fixture, block: 0)
        view.textView.window?.makeFirstResponder(view.textView)
        view.textView.setSelectedRange(NSRange(location: 5, length: 0))
        press(#selector(NSResponder.insertNewline(_:)), in: view, fixture)
        #expect(fixture.texts == ["    x\n    ", "После"])
        fixture.step { view.textView.exitBelow() }
        #expect(fixture.kinds == [.code, .paragraph, .paragraph])
        #expect(fixture.texts == ["    x\n    ", "", "После"])
        #expect(firstResponder(fixture) === fixture.textView)
        #expect(fixture.textView.selectedRange().location == fixture.textLocation(ofBlock: 1))
    }

    @Test("Tab — два пробела; у выделения — у каждой строки; ⇧Tab убирает до двух")
    func tabIndents() throws {
        let fixture = try EditorFixture([Self.code("a\nb\n c")])
        let view = try codeView(fixture, block: 0)
        view.textView.window?.makeFirstResponder(view.textView)
        view.textView.setSelectedRange(NSRange(location: 1, length: 0))
        press(#selector(NSResponder.insertTab(_:)), in: view, fixture)
        #expect(fixture.texts == ["a  \nb\n c"])
        view.textView.setSelectedRange(NSRange(location: 0, length: (view.textView.string as NSString).length))
        press(#selector(NSResponder.insertTab(_:)), in: view, fixture)
        #expect(fixture.texts == ["  a  \n  b\n   c"])
        press(#selector(NSResponder.insertBacktab(_:)), in: view, fixture)
        press(#selector(NSResponder.insertBacktab(_:)), in: view, fixture)
        #expect(fixture.texts == ["a  \nb\nc"])
        fixture.undo()
        #expect(fixture.texts == ["a  \nb\n c"])
    }

    @Test("↑ на первой строке и ↓ на последней — в соседний блок страницы; ↓ в последнем блоке — новый абзац")
    func arrowsLeaveCode() throws {
        let fixture = try EditorFixture([.paragraph("До"), Self.code("one\ntwo"), .paragraph("После")])
        let view = try codeView(fixture, block: 1)
        view.textView.window?.makeFirstResponder(view.textView)
        view.textView.setSelectedRange(NSRange(location: 4, length: 0))
        press(#selector(NSResponder.moveUp(_:)), in: view, fixture)
        #expect(firstResponder(fixture) === view.textView, "со второй строки ↑ — на первую")
        #expect(view.textView.selectedRange().location < 4)
        press(#selector(NSResponder.moveUp(_:)), in: view, fixture)
        #expect(firstResponder(fixture) === fixture.textView)
        #expect(fixture.textView.selectedRange().location == 2, "в конец «До»")

        fixture.window.makeFirstResponder(view.textView)
        view.textView.setSelectedRange(NSRange(location: 5, length: 0))
        press(#selector(NSResponder.moveDown(_:)), in: view, fixture)
        #expect(firstResponder(fixture) === fixture.textView)
        #expect(fixture.textView.selectedRange().location == fixture.textLocation(ofBlock: 2))

        let last = try EditorFixture([.paragraph("До"), Self.code("x")])
        let lastView = try codeView(last, block: 1)
        last.window.makeFirstResponder(lastView.textView)
        press(#selector(NSResponder.moveDown(_:)), in: lastView, last)
        #expect(last.kinds == [.paragraph, .code, .paragraph])
        #expect(last.window.firstResponder === last.textView)
        #expect(last.textView.selectedRange().location == last.textLocation(ofBlock: 2))
    }

    @Test("Стрелки со страницы входят в код: ↓ — в начало, ↑ — в конец")
    func arrowsEnterCode() throws {
        let fixture = try EditorFixture([.paragraph("До"), Self.code("one\ntwo"), .paragraph("После")])
        let view = try codeView(fixture, block: 1)
        fixture.placeCaret(inBlock: 0, at: nil)
        fixture.press(#selector(NSResponder.moveDown(_:)))
        #expect(fixture.window.firstResponder === view.textView)
        #expect(view.textView.selectedRange().location == 0)
        fixture.window.makeFirstResponder(fixture.textView)
        fixture.placeCaret(inBlock: 2, at: 0)
        fixture.press(#selector(NSResponder.moveUp(_:)))
        #expect(fixture.window.firstResponder === view.textView)
        #expect(view.textView.selectedRange().location == 7)
    }

    @Test("⌫ в начале пустого кода — абзац")
    func backspaceInEmptyCode() throws {
        let fixture = try EditorFixture([.paragraph("До"), Self.code("")])
        let view = try codeView(fixture, block: 1)
        fixture.window.makeFirstResponder(view.textView)
        press(#selector(NSResponder.deleteBackward(_:)), in: view, fixture)
        #expect(fixture.kinds == [.paragraph, .paragraph])
        #expect(fixture.window.firstResponder === fixture.textView)
    }

    @Test("«/» и быстрые символы внутри кода не работают")
    func noShortcutsInside() throws {
        let fixture = try EditorFixture([Self.code("")])
        let view = try codeView(fixture, block: 0)
        fixture.window.makeFirstResponder(view.textView)
        type("/- # ```", in: view, fixture)
        #expect(fixture.kinds == [.code])
        #expect(fixture.texts == ["/- # ```"])
        #expect(!fixture.textView.popups.isOpen)
    }

    @Test("«Копировать» — весь код в буфер, надпись «Скопировано»")
    func copyButton() throws {
        let fixture = try EditorFixture([Self.code("let a = 1\nlet b = 2")])
        let view = try codeView(fixture, block: 0)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("mynotion-test-\(UUID().uuidString)"))
        view.pasteboard = pasteboard
        #expect(view.copyButton.title == "Копировать")
        view.copyCode()
        #expect(pasteboard.string(forType: .string) == "let a = 1\nlet b = 2")
        #expect(view.copyButton.title == "Скопировано")
        pasteboard.releaseGlobally()
    }

    @Test("Цвета — атрибуты показа: их нет в тексте и в отмене")
    func highlightIsRenderingOnly() throws {
        let fixture = try EditorFixture([Self.code("let x = 1 // c")])
        try fixture.store.write { tx in
            var block = try #require(try tx.block(fixture.document.blocks[0].id))
            block.props.language = "swift"
            try tx.updateBlock(block)
        }
        let reopened = try EditorFixture(reopening: fixture)
        let view = try codeView(reopened, block: 0)
        let storage = try #require(view.textView.textStorage)
        var colors = Set<NSColor>()
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let color = value as? NSColor { colors.insert(color) }
        }
        #expect(colors.count <= 1, "в самом тексте один цвет")
        #expect(view.renderedColor(at: 0) == CodeBlockStyle.color(for: .keyword))
        #expect(view.renderedColor(at: 8) == CodeBlockStyle.color(for: .number))
        #expect(view.renderedColor(at: 10) == CodeBlockStyle.color(for: .comment))
        #expect(!reopened.undoManager.canUndo)
        // Язык сменился — перекраска.
        reopened.step { view.setLanguage("plain") }
        #expect(view.renderedColor(at: 0) == nil)
    }
}
