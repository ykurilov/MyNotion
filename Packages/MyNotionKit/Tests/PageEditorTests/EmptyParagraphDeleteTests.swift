import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// ⌫ и ⌦ в пустом абзаце убирают его (как в Notion); в блок-ссылку курсор не попадает; ⌘Z возвращает строку.
@MainActor
@Suite("Пустой абзац: ⌫ и ⌦")
struct EmptyParagraphDeleteTests {
    typealias Spec = EditorFixture.Spec
    private var link: Spec { Spec(kind: .pageLink, link: UUID()) }

    private func caretIsInTitle(_ editor: EditorFixture) -> Bool {
        editor.textView.header.titleField.currentEditor() != nil
    }

    @Test("⌫ в пустом первом абзаце над блоком-ссылкой убирает его, курсор уходит в конец заголовка; ⌘Z возвращает")
    func backspaceInEmptyFirstParagraph() throws {
        let editor = try EditorFixture([.paragraph(), link])
        editor.placeCaret(inBlock: 0)
        editor.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(editor.kinds == [.pageLink])
        #expect(caretIsInTitle(editor), "курсор не ушёл в заголовок")
        editor.undo()
        #expect(editor.kinds == [.paragraph, .pageLink])
    }

    @Test("⌫ в единственном пустом абзаце страницы: курсор в заголовке, абзац остаётся")
    func backspaceInOnlyEmptyParagraph() throws {
        let editor = try EditorFixture([.paragraph()])
        editor.placeCaret(inBlock: 0)
        editor.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(editor.kinds == [.paragraph])
        #expect(caretIsInTitle(editor))
    }

    @Test("⌫ в пустом абзаце сразу после блока-ссылки убирает абзац, а не ссылку; ⌘Z возвращает")
    func backspaceAfterPageLink() throws {
        let editor = try EditorFixture([.paragraph("Текст"), link, .paragraph()])
        editor.placeCaret(inBlock: 2)
        editor.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(editor.kinds == [.paragraph, .pageLink])
        editor.undo()
        #expect(editor.kinds == [.paragraph, .pageLink, .paragraph])
    }

    @Test("⌦ в пустом абзаце перед блоком-ссылкой убирает абзац, курсор не в ссылке; ⌘Z возвращает")
    func forwardDeleteBeforePageLink() throws {
        let editor = try EditorFixture([.paragraph("Текст"), .paragraph(), link])
        editor.placeCaret(inBlock: 1)
        editor.press(#selector(NSResponder.deleteForward(_:)))
        #expect(editor.kinds == [.paragraph, .pageLink])
        #expect(!editor.textView.isCaretInPageLink || editor.textView.isBlockSelection, "курсор попал в блок-ссылку")
        editor.undo()
        #expect(editor.kinds == [.paragraph, .paragraph, .pageLink])
    }

    @Test("⌦ в пустом первом абзаце перед блоком-ссылкой и перед картинкой убирает абзац", arguments: [BlockKind.pageLink, .image])
    func forwardDeleteInFirstEmpty(next: BlockKind) throws {
        let editor = try EditorFixture([.paragraph(), Spec(kind: next, link: next == .pageLink ? UUID() : nil)])
        editor.placeCaret(inBlock: 0)
        editor.press(#selector(NSResponder.deleteForward(_:)))
        #expect(editor.kinds == [next])
        #expect(!editor.textView.isCaretInPageLink || editor.textView.isBlockSelection)
        editor.undo()
        #expect(editor.kinds == [.paragraph, next])
    }
}
