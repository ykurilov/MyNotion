import Foundation
import NotesCore
import Testing
@testable import PhonePageEditor

/// Enter, ⌫ в начале блока, чекбокс, переключатель — как в Notion и как у редактора Mac.
@MainActor
struct PageEditingSessionTests {
    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    // MARK: Enter

    @Test func returnSplitsTextKeepingInlineStyles() throws {
        let page = try PhonePageFixture([.paragraph("Жирный текст", runs: [StyledRun(start: 0, length: 12, style: .bold)]), .paragraph("Ниже")])
        let target = try #require(page.session.pressReturn(inBlock: page.ids[0], selection: caret(6)))

        #expect(page.texts == ["Жирный", " текст", "Ниже"])
        #expect(page.document.blocks[0].id == page.ids[0])
        #expect(page.document.blocks[1].text.runs == [StyledRun(start: 0, length: 6, style: .bold)])
        #expect(page.document.blocks[0].text.runs == [StyledRun(start: 0, length: 6, style: .bold)])
        #expect(target == CaretTarget(blockId: page.document.blocks[1].id, offset: 0))
        let saved = try page.savedBlocks()
        #expect(saved.map(\.text.string) == ["Жирный", " текст", "Ниже"])
    }

    @Test func returnReplacesSelectionThenSplits() throws {
        let page = try PhonePageFixture([.paragraph("одиндва")])
        _ = page.session.pressReturn(inBlock: page.ids[0], selection: NSRange(location: 2, length: 3))
        #expect(page.texts == ["од", "ва"])
    }

    @Test func returnContinuesListsAndChecklistsButNotHeadingsOrQuotes() throws {
        let page = try PhonePageFixture([
            .block(.bulletItem, "пункт", indent: 1), .block(.numberedItem, "номер"), .block(.checkbox, "дело", checked: true),
            .block(.heading2, "Заголовок"), .block(.quote, "Цитата"),
        ])
        for id in page.ids { _ = page.session.pressReturn(inBlock: id, selection: caret(try page.block(id).text.utf16Count)) }

        #expect(page.kinds == [.bulletItem, .bulletItem, .numberedItem, .numberedItem, .checkbox, .checkbox,
                               .heading2, .paragraph, .quote, .paragraph])
        #expect(page.document.blocks[1].indent == 1)
        #expect(page.document.blocks[5].isChecked == false)
    }

    @Test func returnInEmptyListItemLeavesTheList() throws {
        let page = try PhonePageFixture([.block(.bulletItem, "пункт"), .block(.bulletItem, "", indent: 1)])
        let target = page.session.pressReturn(inBlock: page.ids[1], selection: caret(0))

        #expect(page.kinds == [.bulletItem, .paragraph])
        #expect(page.document.blocks[1].indent == 0)
        #expect(target == CaretTarget(blockId: page.ids[1], offset: 0))
    }

    @Test func returnInEmptyNestedParagraphOutdents() throws {
        let page = try PhonePageFixture([.block(.bulletItem, "пункт"), .paragraph("", indent: 1)])
        _ = page.session.pressReturn(inBlock: page.ids[1], selection: caret(0))
        #expect(page.document.blocks.count == 2)
        #expect(page.document.blocks[1].indent == 0)
    }

    @Test func returnAtStartOfTextAddsEmptyBlockAbove() throws {
        let page = try PhonePageFixture([.block(.heading1, "Заголовок")])
        let target = page.session.pressReturn(inBlock: page.ids[0], selection: caret(0))

        #expect(page.kinds == [.paragraph, .heading1])
        #expect(page.texts == ["", "Заголовок"])
        #expect(target == CaretTarget(blockId: page.ids[0], offset: 0))
    }

    @Test func returnAtEndOfOpenToggleWithChildrenAddsFirstChild() throws {
        let page = try PhonePageFixture([.block(.toggle, "Раздел"), .paragraph("внутри", indent: 1)])
        let target = try #require(page.session.pressReturn(inBlock: page.ids[0], selection: caret(6)))

        #expect(page.kinds == [.toggle, .paragraph, .paragraph])
        #expect(page.document.blocks.map(\.indent) == [0, 1, 1])
        #expect(target.blockId == page.document.blocks[1].id)
    }

    @Test func returnAtEndOfCollapsedToggleAddsToggleAfterHiddenChildren() throws {
        let page = try PhonePageFixture([.block(.toggle, "Раздел"), .paragraph("внутри", indent: 1), .paragraph("после")])
        page.session.setCollapsed(true, toggle: page.ids[0])
        let target = try #require(page.session.pressReturn(inBlock: page.ids[0], selection: caret(6)))

        #expect(page.texts == ["Раздел", "внутри", "", "после"])
        #expect(page.kinds == [.toggle, .paragraph, .toggle, .paragraph])
        #expect(page.document.blocks[2].indent == 0)
        #expect(target.blockId == page.document.blocks[2].id)
    }

    // MARK: ⌫ в начале блока

    @Test func backspaceTurnsBlockIntoParagraphKeepingText() throws {
        let runs = [StyledRun(start: 0, length: 4, style: .italic)]
        let page = try PhonePageFixture([.paragraph("выше"), .block(.checkbox, "дело", indent: 1, runs: runs, checked: true)])
        let outcome = page.session.pressBackspaceAtStart(ofBlock: page.ids[1])

        let block = try page.block(page.ids[1])
        #expect(block.kind == .paragraph)
        #expect(block.indent == 1)
        #expect(block.isChecked == false)
        #expect(block.text == InlineText("дело", runs: runs))
        #expect(outcome == .caret(CaretTarget(blockId: page.ids[1], offset: 0)))
    }

    @Test func backspaceInNestedParagraphOutdents() throws {
        let page = try PhonePageFixture([.block(.bulletItem, "пункт"), .paragraph("абзац", indent: 1)])
        _ = page.session.pressBackspaceAtStart(ofBlock: page.ids[1])
        #expect(page.texts == ["пункт", "абзац"])
        #expect(page.document.blocks[1].indent == 0)
    }

    @Test func backspaceMergesParagraphIntoPreviousTextBlock() throws {
        let page = try PhonePageFixture([
            .block(.bulletItem, "один", runs: [StyledRun(start: 0, length: 4, style: .bold)]),
            .paragraph("два", runs: [StyledRun(start: 0, length: 3, style: .textColor(.blue))]),
        ])
        let outcome = page.session.pressBackspaceAtStart(ofBlock: page.ids[1])

        #expect(page.kinds == [.bulletItem])
        #expect(page.document.blocks[0].text == InlineText("одиндва", runs: [StyledRun(start: 0, length: 4, style: .bold),
                                                                           StyledRun(start: 4, length: 3, style: .textColor(.blue))]))
        #expect(outcome == .caret(CaretTarget(blockId: page.ids[0], offset: 4)))
    }

    @Test func backspaceMergesIntoCollapsedToggleNotIntoItsHiddenChild() throws {
        let page = try PhonePageFixture([.block(.toggle, "Раздел"), .paragraph("скрыт", indent: 1), .paragraph("текст")])
        page.session.setCollapsed(true, toggle: page.ids[0])
        _ = page.session.pressBackspaceAtStart(ofBlock: page.ids[2])
        #expect(page.texts == ["Разделтекст", "скрыт"])
    }

    @Test func backspaceRemovesEmptyParagraphAfterBlockWithoutText() throws {
        let image = BlockProps(["attachment": .object(["id": .string("x")]), "future": .string("keep")])
        let page = try PhonePageFixture([.paragraph("текст"), .block(.image, props: image), .paragraph("")])
        let outcome = page.session.pressBackspaceAtStart(ofBlock: page.ids[2])

        #expect(page.kinds == [.paragraph, .image])
        #expect(outcome == .caret(CaretTarget(blockId: page.ids[0], offset: 5)))
        #expect(try page.savedBlocks()[1].props == image)
    }

    @Test func backspaceDoesNotGlueTextOntoBlockWithoutText() throws {
        let page = try PhonePageFixture([.block(.divider), .paragraph("текст")])
        #expect(page.session.pressBackspaceAtStart(ofBlock: page.ids[1]) == .unchanged)
        #expect(page.kinds == [.divider, .paragraph])
    }

    @Test func backspaceInEmptyFirstParagraphGoesToTitle() throws {
        let page = try PhonePageFixture([.paragraph(""), .paragraph("второй")])
        #expect(page.session.pressBackspaceAtStart(ofBlock: page.ids[0]) == .title)
        #expect(page.texts == ["второй"])
    }

    // MARK: Касания, название, пустое место

    @Test func tapOnCheckboxTogglesAndSaves() throws {
        let page = try PhonePageFixture([.block(.checkbox, "дело")])
        page.session.toggleChecked(page.ids[0])
        #expect(try page.block(page.ids[0]).isChecked)
        #expect(try page.savedBlocks()[0].isChecked)
        page.session.toggleChecked(page.ids[0])
        #expect(try page.block(page.ids[0]).isChecked == false)
    }

    @Test func collapsedToggleIsRememberedOnThisDevice() throws {
        let page = try PhonePageFixture([.block(.toggle, "Раздел"), .paragraph("внутри", indent: 1)])
        page.session.setCollapsed(true, toggle: page.ids[0])
        let reopened = PageEditingSession(document: page.document, viewState: BlockViewStateStore(database: page.store.database))
        #expect(reopened.collapsedBlockIds == [page.ids[0]])
    }

    @Test func collapsedChangedOutsideEditorIsReloaded() throws {
        let page = try PhonePageFixture([.block(.toggle, "Раздел"), .paragraph("внутри", indent: 1)])
        var notified = 0
        page.session.onCollapsedChange = { notified += 1 }

        try BlockViewStateStore(database: page.store.database).setCollapsed(true, blockId: page.ids[0])
        BlockViewStateStore.postChangedOutsideEditor(pageId: UUID())
        #expect(notified == 0)
        BlockViewStateStore.postChangedOutsideEditor(pageId: page.pageId)

        #expect(notified == 1)
        #expect(page.session.collapsedBlockIds == [page.ids[0]])
        #expect(page.session.rows().map(\.block.id) == [page.ids[0]])
    }

    @Test func returnInTitleGoesToFirstTextBlockOrAddsOne() throws {
        let page = try PhonePageFixture([.paragraph("первый")])
        #expect(page.session.returnFromTitle() == CaretTarget(blockId: page.ids[0], offset: 0))

        let withImage = try PhonePageFixture([.block(.image)])
        let target = withImage.session.returnFromTitle()
        #expect(withImage.kinds == [.paragraph, .image])
        #expect(target.blockId == withImage.document.blocks[0].id)
    }

    @Test func tapBelowLastBlockReusesEmptyParagraphOrAddsOne() throws {
        let page = try PhonePageFixture([.paragraph("текст")])
        let added = page.session.tapBelowLastBlock()
        #expect(page.texts == ["текст", ""])
        #expect(page.session.tapBelowLastBlock() == added)
        #expect(page.document.blocks.count == 2)
    }

    @Test func titleEditIsSaved() throws {
        let page = try PhonePageFixture([.paragraph()])
        page.session.setTitle("Новое название")
        _ = try page.savedBlocks()
        #expect(try page.store.page(page.pageId)?.title == "Новое название")
    }

    // MARK: Чужие данные

    @Test func editsKeepUnknownPropsAndBlocksIntact() throws {
        let callout = BlockProps(["icon": .string("💡"), "future": .number(7)])
        let page = try PhonePageFixture([.block(.callout, "выноска", props: callout), .paragraph("текст"), .block(.code, "let x = 1")])
        let before = try page.store.pageContent(page.pageId)!.blocks

        _ = page.session.pressReturn(inBlock: page.ids[1], selection: caret(2))
        _ = page.session.pressBackspaceAtStart(ofBlock: page.document.blocks[2].id)
        let saved = try page.savedBlocks()

        #expect(saved.map(\.text.string) == ["выноска", "текст", "let x = 1"])
        #expect(saved[0] == before[0])
        #expect(saved[2] == before[2])
    }
}
