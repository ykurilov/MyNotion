import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// Свёрнутый заголовок или переключатель действует как одно целое, как в Notion: выделение блоков, стрелки,
/// ⌦, ⌫, ⌥⇧↑↓ и перетаскивание не разрывают раздел и не роняют блоки внутрь спрятанного.
@MainActor
@Suite("Свёрнутый раздел как целое")
struct CollapsedSectionTests {
    typealias Fold = HeadingFoldTests

    /// Тот же лист, что у `HeadingFoldTests`, со свёрнутым H2 «Раздел» (спрятаны блоки 2…5).
    static func collapsedFixture() throws -> EditorFixture {
        let editor = try Fold.makeFixture()
        Fold.collapse(editor)
        return editor
    }

    @Test("⋮⋮ / Esc на свёрнутом заголовке выделяет его с разделом: ⌘C берёт раздел, Delete удаляет его")
    func blockSelectionTakesSection() throws {
        let editor = try Self.collapsedFixture()
        editor.textView.selectBlocks(Fold.headingIndex..<Fold.headingIndex + 1)
        #expect(editor.textView.selectedBlocks == 1..<6)

        let board = NSPasteboard(name: NSPasteboard.Name("CollapsedSectionTests-\(UUID().uuidString)"))
        board.clearContents()
        _ = editor.textView.writeSelection(to: board, types: editor.textView.writablePasteboardTypes)
        let target = try EditorFixture([.paragraph()])
        target.step { target.textView.paste(from: board) }
        #expect(target.texts == ["Раздел", "а", "т", "т1", "Под"])

        editor.textView.selectBlocks(Fold.headingIndex..<Fold.headingIndex + 1)
        editor.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(editor.texts == ["до", "Следующий", "после"])
        editor.undo()
        #expect(editor.texts == Fold.allTexts)
    }

    @Test("«Преобразовать» на выделенном свёрнутом заголовке меняет только заголовок")
    func turnIntoKeepsSectionKinds() throws {
        let editor = try Self.collapsedFixture()
        let sectionKinds = Array(editor.kinds[Fold.section])
        editor.textView.selectBlocks(Fold.headingIndex..<Fold.headingIndex + 1)
        editor.perform(.setKind(.heading1))
        #expect(editor.kinds[Fold.headingIndex] == .heading1)
        #expect(Array(editor.kinds[Fold.section]) == sectionKinds)
    }

    @Test("Стрелки в режиме блоков шагают через свёрнутый раздел и не раскрывают его")
    func arrowsSkipHiddenBlocks() throws {
        let editor = try Self.collapsedFixture()
        editor.textView.selectBlocks(Fold.nextIndex..<Fold.nextIndex + 1)
        editor.press(#selector(NSResponder.moveUp(_:)))
        #expect(editor.textView.selectedBlocks == 1..<6)
        #expect(editor.textView.collapsedBlockIds == [Fold.headingId(editor)])
        editor.press(#selector(NSResponder.moveDown(_:)))
        #expect(editor.textView.selectedBlocks == 6..<7)

        editor.press(#selector(NSResponder.moveUpAndModifySelection(_:)))
        #expect(editor.textView.selectedBlocks == 1..<7)
        editor.textView.selectBlocks(Fold.headingIndex..<Fold.headingIndex + 1)
        editor.press(#selector(NSResponder.moveDownAndModifySelection(_:)))
        #expect(editor.textView.selectedBlocks == 1..<7)
        #expect(editor.textView.collapsedBlockIds == [Fold.headingId(editor)])
    }

    @Test("⌦ в конце свёрнутого заголовка не втягивает спрятанный блок")
    func deleteForwardAtCollapsedHeading() throws {
        let editor = try Self.collapsedFixture()
        editor.placeCaret(inBlock: Fold.headingIndex, at: nil)
        editor.press(#selector(NSResponder.deleteForward(_:)))
        #expect(editor.texts == Fold.allTexts)
    }

    @Test("⌦ в конце свёрнутого переключателя склеивает с ним абзац после детей, дети остаются")
    func deleteForwardAtCollapsedToggle() throws {
        let editor = try EditorFixture([EditorFixture.Spec(kind: .toggle, text: "т"), EditorFixture.Spec(kind: .paragraph, text: "т1", indent: 1),
                                        .paragraph("после")])
        editor.textView.blockViewState = BlockViewStateStore(database: editor.store.database)
        editor.textView.setCollapsed(true, ofBlock: editor.document.blocks[0].id)
        editor.placeCaret(inBlock: 0, at: nil)
        editor.press(#selector(NSResponder.deleteForward(_:)))
        #expect(editor.texts == ["тпосле", "т1"])
    }

    @Test("⌫ в начале заголовка под свёрнутым заголовком раскрывает верхний: абзац остаётся на виду")
    func backspaceHeadingUnderCollapsedHeading() throws {
        let editor = try Self.collapsedFixture()
        editor.placeCaret(inBlock: Fold.nextIndex)
        editor.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(editor.kinds[Fold.nextIndex] == .paragraph)
        #expect(editor.textView.hiddenParagraphs.hiddenBlockIds.isEmpty)
    }

    @Test("⌥⇧↓ над свёрнутым заголовком и ⌥⇧↑ под ним переступают раздел целиком")
    func moveKeysStepOverSection() throws {
        let editor = try Self.collapsedFixture()
        editor.placeCaret(inBlock: 0)
        editor.perform(.moveBlocksDown)
        #expect(editor.texts == ["Раздел", "а", "т", "т1", "Под", "до", "Следующий", "после"])
        editor.undo()

        editor.placeCaret(inBlock: Fold.nextIndex)
        editor.perform(.moveBlocksUp)
        #expect(editor.texts == ["до", "Следующий", "Раздел", "а", "т", "т1", "Под", "после"])
    }

    @Test("Перетаскивание ⋮⋮: зазор под блоком ниже свёрнутого раздела — по номеру этого блока")
    func dropGapBelowCollapsedSection() throws {
        let editor = try Self.collapsedFixture()
        editor.layoutViewport()
        let frames = editor.textView.visibleBlockFrames()
        let next = try #require(frames.first { $0.index == Fold.nextIndex })
        let gap = try #require(editor.textView.dropGap(atY: next.frame.upperBound - 1))
        #expect(gap.index == Fold.nextIndex + 1)
        let above = try #require(editor.textView.dropGap(atY: next.frame.lowerBound + 1))
        #expect(above.index == Fold.nextIndex)
    }
}
