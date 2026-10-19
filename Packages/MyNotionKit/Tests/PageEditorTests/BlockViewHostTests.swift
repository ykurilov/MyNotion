import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// Блок без своего текста на странице (research R2): абзац из одного знака-вложения U+FFFC и перевода строки,
/// вид блока живёт во вложении.
@MainActor
@Suite("Вид-вложение блока")
struct BlockViewHostTests {
    /// Абзац, разделитель, картинка с подписью, абзац.
    func makeFixture() throws -> EditorFixture {
        let fixture = try EditorFixture([.paragraph("До"), Spec(kind: .divider), Spec(kind: .image, text: "подпись"), .paragraph("После")])
        try fixture.store.write { tx in
            var image = try #require(try tx.block(fixture.document.blocks[2].id))
            image.props.width = 0.5
            try tx.updateBlock(image)
        }
        return try EditorFixture(reopening: fixture)
    }

    typealias Spec = EditorFixture.Spec

    @Test("Абзац блока без текста — один U+FFFC и перевод строки, на знаке — вложение блока")
    func attachmentParagraph() throws {
        let fixture = try makeFixture()
        let string = fixture.textView.string as NSString
        #expect(fixture.textView.string == "До\n\u{FFFC}\n\u{FFFC}\nПосле\n")
        for index in [1, 2] {
            let location = fixture.textLocation(ofBlock: index)
            #expect(string.character(at: location) == 0xFFFC)
            let attachment = fixture.textView.textStorage?.attribute(.attachment, at: location, effectiveRange: nil) as? BlockAttachment
            #expect(attachment?.blockId == fixture.document.blocks[index].id)
        }
    }

    @Test("Мэппер берёт текст и свойства таких блоков из документа, а не со страницы")
    func mapperKeepsDocumentText() throws {
        let fixture = try makeFixture()
        fixture.placeCaret(inBlock: 3, at: nil)
        fixture.type("!")
        fixture.placeCaret(inBlock: 0, at: nil)
        fixture.press(#selector(NSResponder.insertNewline(_:)))
        let image = try #require(fixture.document.blocks.first { $0.kind == .image })
        #expect(image.text.string == "подпись")
        #expect(image.props.width == 0.5)
        #expect(fixture.document.blocks.first { $0.kind == .divider }?.text == .empty)
        let saved = try fixture.savedBlocks()
        #expect(saved.first { $0.kind == .image }?.text.string == "подпись")
        #expect(saved.first { $0.kind == .image }?.props.width == 0.5)
    }

    @Test("Курсор внутрь не встаёт — перешагивает в сторону движения")
    func caretSkipsAttachment() throws {
        let fixture = try makeFixture()
        let dividerStart = fixture.textLocation(ofBlock: 1)
        fixture.placeCaret(inBlock: 0, at: nil)
        // Вперёд: из конца «До» на место разделителя — к началу «После» через оба вложения.
        fixture.textView.setSelectedRange(NSRange(location: dividerStart, length: 0))
        #expect(fixture.textView.selectedRange() == NSRange(location: fixture.textLocation(ofBlock: 3), length: 0))
        // Назад: из начала «После» на место картинки — в конец «До».
        fixture.textView.setSelectedRange(NSRange(location: fixture.textLocation(ofBlock: 2) + 1, length: 0))
        #expect(fixture.textView.selectedRange() == NSRange(location: 2, length: 0))
        // Стрелки тоже перешагивают.
        fixture.press(#selector(NSResponder.moveRight(_:)))
        #expect(fixture.textView.selectedRange() == NSRange(location: fixture.textLocation(ofBlock: 3), length: 0))
        fixture.press(#selector(NSResponder.moveLeft(_:)))
        #expect(fixture.textView.selectedRange() == NSRange(location: 2, length: 0))
        // Выделение через вложение — можно.
        fixture.textView.setSelectedRange(NSRange(location: 1, length: dividerStart + 2))
        #expect(fixture.textView.selectedRange().length == dividerStart + 2)
    }

    @Test("Набор и вставка в абзац вложения не попадают")
    func noTextIntoAttachment() throws {
        let fixture = try makeFixture()
        let dividerStart = fixture.textLocation(ofBlock: 1)
        #expect(!fixture.textView.shouldChangeText(in: NSRange(location: dividerStart + 1, length: 0), replacementString: "x"))
    }

    @Test("Щелчок по виду — режим выделения блоков; ⌘Z удаления такого блока возвращает его")
    func clickSelectsBlockAndUndoRestores() throws {
        let fixture = try makeFixture()
        let image = fixture.document.blocks[2]
        fixture.step { fixture.textView.attachmentViewClicked(blockId: image.id) }
        #expect(fixture.textView.isBlockSelection)
        #expect(fixture.textView.selectedBlockRange() == 2..<3)
        fixture.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(fixture.kinds == [.paragraph, .divider, .paragraph])
        fixture.undo()
        #expect(fixture.kinds == [.paragraph, .divider, .image, .paragraph])
        // Как у всех блоков 001, возвращённый ⌘Z блок — новая запись с тем же содержимым.
        let restored = try #require(fixture.document.blocks.first { $0.kind == .image })
        #expect(restored.text.string == "подпись")
        #expect(restored.props.width == 0.5)
        #expect(fixture.textView.string == "До\n\u{FFFC}\n\u{FFFC}\nПосле\n")
    }

    @Test("Вид создаёт фабрика приложения; без неё — заглушка с высотой строки")
    func viewFactories() throws {
        final class Factory: BlockViewFactory {
            var made: [BlockKind] = []
            func makeView(for block: Block, context: BlockViewContext) -> NSView? {
                made.append(block.kind)
                return NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
            }
            func height(for block: Block, width: CGFloat) -> CGFloat? { block.kind == .image ? 200 : nil }
        }
        let factory = Factory()
        BlockViewFactories.shared.register(factory, for: .image)
        defer { BlockViewFactories.shared.unregister(.image) }
        let fixture = try makeFixture()
        let attachment = try #require(fixture.textView.textStorage?.attribute(.attachment, at: fixture.textLocation(ofBlock: 2),
                                                                             effectiveRange: nil) as? BlockAttachment)
        #expect(attachment.height(forWidth: 720) == 200)
        let divider = try #require(fixture.textView.textStorage?.attribute(.attachment, at: fixture.textLocation(ofBlock: 1),
                                                                          effectiveRange: nil) as? BlockAttachment)
        #expect(divider.height(forWidth: 720) == BlockAttachment.placeholderHeight)
        let view = BlockAttachmentViewProvider.makeHostedView(for: attachment, textView: fixture.textView)
        #expect(factory.made == [.image])
        #expect(view.subviews.count == 1)
    }
}
