import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// Свёрнутый заголовок: блоки его раздела прячутся от раскладки так же, как дети свёрнутого переключателя; справа
/// от текста — «…N блоков», слева в ручках вместо «+» — стрелка. Свёрнутость — на этом Mac, в `block_view_state`.
@MainActor
@Suite("Свёртывание заголовка")
struct HeadingFoldTests {
    typealias Spec = EditorFixture.Spec

    /// «до», H2 «Раздел» с «а», переключателем «т» (ребёнок «т1») и H3 «Под»; затем H2 «Следующий» и «после».
    static func makeFixture() throws -> EditorFixture {
        let editor = try EditorFixture([.paragraph("до"), .heading(2, "Раздел"), .paragraph("а"), Spec(kind: .toggle, text: "т"),
                                        Spec(kind: .paragraph, text: "т1", indent: 1), .heading(3, "Под"), .heading(2, "Следующий"),
                                        .paragraph("после")])
        editor.textView.blockViewState = BlockViewStateStore(database: editor.store.database)
        return editor
    }

    static let headingIndex = 1
    static let section = 2...5
    static let nextIndex = 6
    static let allTexts = ["до", "Раздел", "а", "т", "т1", "Под", "Следующий", "после"]

    static func headingId(_ editor: EditorFixture) -> UUID { editor.document.blocks[headingIndex].id }

    static func collapse(_ editor: EditorFixture) {
        editor.textView.setCollapsed(true, ofBlock: headingId(editor))
    }

    static func sectionIds(_ editor: EditorFixture) -> Set<UUID> {
        Set(editor.document.blocks[section].map(\.id))
    }

    static func headingLineEnd(_ editor: EditorFixture) -> Int {
        editor.textLocation(ofBlock: headingIndex) + ("Раздел" as NSString).length
    }

    @Test("Свёрнутый H2 прячет свой раздел до следующего H2; текст страницы не меняется; разворот возвращает")
    func collapsedHeadingHidesSection() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        #expect(editor.textView.collapsedBlockIds == [Self.headingId(editor)])
        #expect(editor.textView.hiddenParagraphs.hiddenBlockIds == Self.sectionIds(editor))
        #expect(HiddenParagraphsTests.laidOutBlockIds(editor).isDisjoint(with: Self.sectionIds(editor)))
        #expect(editor.texts == Self.allTexts)
        #expect(editor.textView.foldedLabel(ofBlock: Self.headingId(editor)) == "…3 блока")

        editor.textView.setCollapsed(false, ofBlock: Self.headingId(editor))
        #expect(editor.textView.hiddenParagraphs.hiddenBlockIds.isEmpty)
        #expect(editor.textView.foldedLabel(ofBlock: Self.headingId(editor)) == nil)
    }

    @Test("Свёрнутость заголовка возвращается при новом открытии страницы")
    func collapsedHeadingSurvivesReopen() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        let reopened = try EditorFixture(reopening: editor)
        reopened.textView.blockViewState = BlockViewStateStore(database: reopened.store.database)
        #expect(reopened.textView.collapsedBlockIds == [Self.headingId(reopened)])
        #expect(reopened.textView.hiddenParagraphs.hiddenBlockIds == Self.sectionIds(reopened))
    }

    @Test("Курсор внутри раздела при свёртывании уходит в конец заголовка")
    func caretInsideSectionMovesToHeadingEnd() throws {
        let editor = try Self.makeFixture()
        editor.placeCaret(inBlock: 4, at: 1)
        Self.collapse(editor)
        #expect(editor.textView.selectedRange() == NSRange(location: Self.headingLineEnd(editor), length: 0))
        editor.placeCaret(inBlock: 2, at: 1)
        #expect(editor.textView.selectedRange() == NSRange(location: Self.headingLineEnd(editor), length: 0), "курсор не попадает в скрытое")
    }

    @Test("Щелчок по «…N блоков» разворачивает; щелчок по тексту заголовка — нет")
    func clickOnLabelExpands() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        let label = try #require(editor.textView.foldedLabelRect(ofBlock: Self.headingId(editor)))
        #expect(!editor.textView.handleStructuralBlockClick(at: NSPoint(x: label.minX - 30, y: label.midY)), "текст заголовка — обычная правка")
        #expect(!editor.textView.collapsedBlockIds.isEmpty)
        #expect(editor.textView.handleStructuralBlockClick(at: NSPoint(x: label.midX, y: label.midY)))
        #expect(editor.textView.collapsedBlockIds.isEmpty)
    }

    @Test("Ручки заголовка: вместо «+» — стрелка свёртывания; у абзаца остаётся «+»")
    func headingHandleFolds() throws {
        let editor = try Self.makeFixture()
        let handles = editor.textView.blockHandles
        let headingLine = try #require(editor.textView.markerLine(ofBlockAt: Self.headingIndex))
        handles.show(forBlockAt: Self.headingIndex, line: headingLine)
        #expect(handles.addHandle.accessibilityIdentifier() == "block-handle-fold")
        #expect(handles.addHandle.accessibilityLabel() == "Свернуть")
        #expect(handles.addHandle.accessibilityPerformPress())
        #expect(editor.textView.collapsedBlockIds == [Self.headingId(editor)])
        #expect(handles.addHandle.accessibilityLabel() == "Развернуть")
        #expect(editor.document.blocks.count == Self.allTexts.count, "блок не добавлен")
        #expect(handles.addHandle.accessibilityPerformPress())
        #expect(editor.textView.collapsedBlockIds.isEmpty)

        let paragraphLine = try #require(editor.textView.markerLine(ofBlockAt: 0))
        handles.show(forBlockAt: 0, line: paragraphLine)
        #expect(handles.addHandle.accessibilityIdentifier() == "block-handle-add")
    }

    @Test("Enter в конце свёрнутого заголовка — новый абзац после скрытой части, заголовок разворачивается; ⌘Z убирает абзац")
    func enterAtEndInsertsAfterSection() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        editor.placeCaret(inBlock: Self.headingIndex, at: nil)
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(editor.texts == ["до", "Раздел", "а", "т", "т1", "Под", "", "Следующий", "после"])
        #expect(editor.kinds[Self.nextIndex] == .paragraph)
        #expect(editor.textView.selectedRange() == NSRange(location: editor.textLocation(ofBlock: Self.nextIndex), length: 0))
        #expect(editor.textView.hiddenParagraphs.hiddenBlockIds.isEmpty, "абзац входит в раздел: заголовок развёрнут, абзац виден")
        editor.undo()
        #expect(editor.texts == Self.allTexts)
    }

    @Test("Enter в начале свёрнутого заголовка — пустой абзац над ним, заголовок с текстом остаётся свёрнутым")
    func enterAtStartInsertsAbove() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        let headingId = Self.headingId(editor)
        editor.placeCaret(inBlock: Self.headingIndex, at: 0)
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(editor.texts == ["до", "", "Раздел", "а", "т", "т1", "Под", "Следующий", "после"])
        #expect(editor.document.blocks[2].id == headingId)
        #expect(editor.textView.collapsedBlockIds == [headingId])
        #expect(editor.textView.hiddenParagraphs.hiddenBlockIds == Set(editor.document.blocks[3...6].map(\.id)))
    }

    @Test("Переход к спрятанному блоку и выделение в нём (⌘F) разворачивают заголовок")
    func revealAndFindExpand() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        editor.textView.revealBlock(editor.document.blocks[4].id)
        #expect(editor.textView.collapsedBlockIds.isEmpty)
        #expect(editor.textView.selectedRange().location == editor.textLocation(ofBlock: 4))

        Self.collapse(editor)
        editor.select(inBlock: 5, "Под")
        #expect(editor.textView.collapsedBlockIds.isEmpty)
        #expect(editor.textView.selectedRange() == NSRange(location: editor.textLocation(ofBlock: 5), length: 3))
    }

    @Test("Перетаскивание свёрнутого заголовка переносит его вместе со скрытым; ⌘Z возвращает")
    func dragMovesSection() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        let headingId = Self.headingId(editor)
        editor.step { editor.textView.moveBlock(headingId, toGap: 8) }
        #expect(editor.texts == ["до", "Следующий", "после", "Раздел", "а", "т", "т1", "Под"])
        #expect(editor.textView.collapsedBlockIds == [headingId])
        editor.undo()
        #expect(editor.texts == Self.allTexts)

        editor.placeCaret(inBlock: Self.headingIndex, at: nil)
        editor.perform(.moveBlocksDown)
        #expect(editor.texts == ["до", "Следующий", "Раздел", "а", "т", "т1", "Под", "после"], "⌥⇧↓ — тоже со скрытым")
    }

    @Test("Заголовок, ставший абзацем или удалённый, ничего не прячет; скрытое остаётся на странице")
    func headingGoneShowsSection() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        editor.placeCaret(inBlock: Self.headingIndex)
        editor.perform(.setKind(.paragraph))
        #expect(editor.textView.hiddenParagraphs.hiddenBlockIds.isEmpty)
        editor.undo()
        #expect(editor.textView.hiddenParagraphs.hiddenBlockIds == Self.sectionIds(editor))

        editor.step { editor.textView.removeBlocks(at: Self.headingIndex..<Self.headingIndex + 1) }
        #expect(editor.texts == ["до", "а", "т", "т1", "Под", "Следующий", "после"])
        #expect(editor.textView.hiddenParagraphs.hiddenBlockIds.isEmpty)
    }

    @Test("⌘Z не задет свёртыванием заголовка")
    func undoIgnoresHeadingFold() throws {
        let editor = try Self.makeFixture()
        editor.placeCaret(inBlock: 0, at: nil)
        editor.type("1")
        Self.collapse(editor)
        editor.undo()
        #expect(editor.texts.first == "до")
        #expect(!editor.textView.collapsedBlockIds.isEmpty)
        #expect(editor.undoManager.canUndo == false)
    }
}
