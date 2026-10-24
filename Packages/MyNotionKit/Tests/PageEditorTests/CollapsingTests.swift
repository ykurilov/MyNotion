import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// Свёртывание переключателя (research R1; contracts/blocks-and-keys.md, «Раскрывающийся список»):
/// дети прячутся от раскладки, текст страницы не меняется; свои правила курсора, ⌫ и выделения.
@MainActor
@Suite("Свёртывание переключателя")
struct CollapsingTests {
    typealias Spec = EditorFixture.Spec

    /// «до», переключатель «Р» с детьми «а», «б» (под «а»), «в», затем «после».
    static func makeFixture() throws -> EditorFixture {
        let editor = try EditorFixture([.paragraph("до"), Spec(kind: .toggle, text: "Р"), Spec(kind: .paragraph, text: "а", indent: 1),
                                        Spec(kind: .paragraph, text: "б", indent: 2), Spec(kind: .paragraph, text: "в", indent: 1),
                                        .paragraph("после")])
        editor.textView.blockViewState = BlockViewStateStore(database: editor.store.database)
        return editor
    }

    static let toggleIndex = 1
    static let children = 2...4
    static let afterIndex = 5

    static func collapse(_ editor: EditorFixture) {
        editor.textView.setCollapsed(true, ofBlock: editor.document.blocks[toggleIndex].id)
    }

    static func childIds(_ editor: EditorFixture) -> Set<UUID> {
        Set(editor.document.blocks[children].map(\.id))
    }

    /// Конец текста переключателя в тексте страницы.
    static func toggleLineEnd(_ editor: EditorFixture) -> Int {
        editor.textLocation(ofBlock: toggleIndex) + 1
    }

    @Test("Свёрнутые дети не раскладываются; раскрытие возвращает их")
    func hiddenChildrenHaveNoLayout() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        #expect(editor.textView.hiddenParagraphs.hiddenBlockIds == Self.childIds(editor))
        #expect(HiddenParagraphsTests.laidOutBlockIds(editor).isDisjoint(with: Self.childIds(editor)))
        #expect(editor.texts == ["до", "Р", "а", "б", "в", "после"], "текст страницы не меняется")

        editor.textView.setCollapsed(false, ofBlock: editor.document.blocks[Self.toggleIndex].id)
        #expect(editor.textView.hiddenParagraphs.hiddenBlockIds.isEmpty)
        #expect(HiddenParagraphsTests.laidOutBlockIds(editor).count == 6)
    }

    @Test("Курсор, попавший внутрь скрытого, уходит к концу строки переключателя")
    func caretInsideHiddenMovesToToggleEnd() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        editor.placeCaret(inBlock: 3, at: 1)
        #expect(editor.textView.selectedRange() == NSRange(location: Self.toggleLineEnd(editor), length: 0))
        #expect(!editor.textView.collapsedBlockIds.isEmpty, "курсор не раскрывает")
    }

    @Test("→ в конце свёрнутого переключателя — в начало следующего видимого блока; ← обратно — в конец переключателя")
    func arrowsSkipHidden() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        editor.placeCaret(inBlock: Self.toggleIndex, at: nil)
        editor.press(#selector(NSResponder.moveRight(_:)))
        #expect(editor.textView.selectedRange().location == editor.textLocation(ofBlock: Self.afterIndex))
        editor.press(#selector(NSResponder.moveLeft(_:)))
        #expect(editor.textView.selectedRange().location == Self.toggleLineEnd(editor))
    }

    @Test("⌫ в начале блока под свёрнутым склеивает его с текстом переключателя")
    func backspaceUnderCollapsedJoinsToggle() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        editor.placeCaret(inBlock: Self.afterIndex)
        editor.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(editor.texts == ["до", "Рпосле", "а", "б", "в"])
        #expect(editor.textView.selectedRange() == NSRange(location: Self.toggleLineEnd(editor), length: 0))
        #expect(editor.textView.hiddenParagraphs.hiddenBlockIds == Self.childIds(editor), "переключатель остаётся свёрнутым")
        editor.undo()
        #expect(editor.texts == ["до", "Р", "а", "б", "в", "после"])
    }

    @Test("Выделение через свёрнутый захватывает его детей: удаление — вместе с ними")
    func selectionAcrossCollapsedTakesChildren() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        editor.placeCaret(inBlock: Self.toggleIndex, at: nil)
        editor.press(#selector(NSResponder.moveDownAndModifySelection(_:)))
        let selection = editor.textView.selectedRange()
        #expect(NSMaxRange(selection) >= editor.textLocation(ofBlock: Self.afterIndex))

        // Выделение от начала переключателя до начала «после» — переключатель с детьми целиком.
        let start = editor.textLocation(ofBlock: Self.toggleIndex)
        editor.textView.setSelectedRange(NSRange(location: start, length: editor.textLocation(ofBlock: Self.afterIndex) - start))
        editor.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(!editor.texts.contains("а") && !editor.texts.contains("б") && !editor.texts.contains("в"))
        #expect(editor.texts.first == "до" && editor.texts.last == "после")
        editor.undo()
        #expect(editor.texts == ["до", "Р", "а", "б", "в", "после"])
    }

    @Test("Выделение внутри скрытого (как ⌘F) раскрывает всех свёрнутых предков")
    func selectionInsideHiddenExpandsAncestors() throws {
        let editor = try EditorFixture([Spec(kind: .toggle, text: "Внешний"), Spec(kind: .toggle, text: "Внутренний", indent: 1),
                                        Spec(kind: .paragraph, text: "слово", indent: 2), .paragraph("после")])
        editor.textView.blockViewState = BlockViewStateStore(database: editor.store.database)
        let outer = editor.document.blocks[0].id
        let inner = editor.document.blocks[1].id
        editor.textView.setCollapsed(true, ofBlock: inner)
        editor.textView.setCollapsed(true, ofBlock: outer)
        #expect(editor.textView.collapsedBlockIds == [outer, inner])

        editor.select(inBlock: 2, "слово")
        #expect(editor.textView.collapsedBlockIds.isEmpty)
        #expect(editor.textView.hiddenParagraphs.hiddenBlockIds.isEmpty)
        let found = editor.textView.selectedRange()
        #expect(found == NSRange(location: editor.textLocation(ofBlock: 2), length: 5), "выделение остаётся на найденном")
    }

    @Test("Переход к блоку (поиск страниц) раскрывает предков и ставит курсор в блок")
    func revealBlockExpandsAncestors() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        editor.textView.revealBlock(editor.document.blocks[3].id)
        #expect(editor.textView.collapsedBlockIds.isEmpty)
        #expect(editor.textView.selectedRange().location == editor.textLocation(ofBlock: 3))
    }

    @Test("⌘Enter сворачивает и раскрывает переключатель под курсором; щелчок по треугольнику — тоже")
    func commandEnterToggles() throws {
        let editor = try Self.makeFixture()
        editor.placeCaret(inBlock: Self.toggleIndex, at: 1)
        editor.perform(.toggleChecked)
        #expect(editor.textView.collapsedBlockIds == [editor.document.blocks[Self.toggleIndex].id])
        editor.perform(.toggleChecked)
        #expect(editor.textView.collapsedBlockIds.isEmpty)
        #expect(EditorKeyBindings.command(characters: "\r", modifiers: [.command]) == .toggleChecked)

        let triangle = try #require(editor.textView.toggleTriangleRect(ofBlock: editor.document.blocks[Self.toggleIndex].id))
        #expect(editor.textView.toggle(at: NSPoint(x: triangle.midX, y: triangle.midY)) == editor.document.blocks[Self.toggleIndex].id)
        #expect(editor.textView.toggle(at: NSPoint(x: triangle.maxX + 200, y: triangle.midY)) == nil, "щелчок по тексту не переключает")
    }

    @Test("⌘⌥T сворачивает все переключатели страницы, повтор — раскрывает все")
    func commandOptionTTogglesAll() throws {
        let editor = try EditorFixture([Spec(kind: .toggle, text: "А"), Spec(kind: .paragraph, text: "а", indent: 1),
                                        Spec(kind: .toggle, text: "Б"), Spec(kind: .paragraph, text: "б", indent: 1)])
        #expect(EditorKeyBindings.command(characters: "t", modifiers: [.command, .option]) == .toggleAllCollapsed)
        editor.perform(.toggleAllCollapsed)
        #expect(editor.textView.collapsedBlockIds == [editor.document.blocks[0].id, editor.document.blocks[2].id])
        editor.perform(.toggleAllCollapsed)
        #expect(editor.textView.collapsedBlockIds.isEmpty)
    }

    @Test("⌘Z и ⇧⌘Z не задеты свёртыванием: правки до и после возвращаются, свёрнутость не отменяется")
    func undoIgnoresCollapsing() throws {
        let editor = try Self.makeFixture()
        editor.placeCaret(inBlock: 0, at: nil)
        editor.type("1")
        Self.collapse(editor)
        editor.placeCaret(inBlock: Self.afterIndex, at: nil)
        editor.type("2")
        #expect(editor.texts == ["до1", "Р", "а", "б", "в", "после2"])

        editor.undo()
        #expect(editor.texts.last == "после")
        #expect(!editor.textView.collapsedBlockIds.isEmpty, "⌘Z свёрнутость не трогает")
        editor.undo()
        #expect(editor.texts.first == "до")
        #expect(!editor.textView.collapsedBlockIds.isEmpty)
        #expect(editor.undoManager.canUndo == false, "свёртывание не стало шагом отмены")
        editor.redo()
        editor.redo()
        #expect(editor.texts == ["до1", "Р", "а", "б", "в", "после2"])
    }

    @Test("Свёрнутость пишется сразу и возвращается при новом открытии страницы")
    func collapsedStateSurvivesReopen() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        let reopened = try EditorFixture(reopening: editor)
        reopened.textView.blockViewState = BlockViewStateStore(database: reopened.store.database)
        #expect(reopened.textView.collapsedBlockIds == [reopened.document.blocks[Self.toggleIndex].id])
        #expect(reopened.textView.hiddenParagraphs.hiddenBlockIds == Self.childIds(reopened))
    }

    @Test("Новый ребёнок свёрнутого переключателя (Tab под ним) тоже прячется")
    func hiddenSetFollowsStructure() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        editor.placeCaret(inBlock: Self.afterIndex)
        editor.press(#selector(NSResponder.insertTab(_:)))
        #expect(editor.indents[Self.afterIndex] == 1)
        #expect(editor.textView.hiddenParagraphs.hiddenBlockIds.contains(editor.document.blocks[Self.afterIndex].id))
    }

    @Test("Переключатель, ставший абзацем, ничего не прячет")
    func nonToggleHidesNothing() throws {
        let editor = try Self.makeFixture()
        Self.collapse(editor)
        editor.placeCaret(inBlock: Self.toggleIndex)
        editor.perform(.setKind(.bulletItem))
        #expect(editor.textView.hiddenParagraphs.hiddenBlockIds.isEmpty)
    }

    /// Открытие страницы ставит отступы детям цитат, выносок и переключателей (T085, профиль переключения вкладок):
    /// абзацы перебираются по порядку блоков, и поиск начала абзаца идёт от прошлого, а не с начала текста.
    /// Вразнобой (порядок множества) 3 000 детей стоили 0,42 с, по порядку — 0,03 с (iMac, отладочная сборка).
    @Test("3 000 детей цитаты: отступы ставятся одним проходом по тексту")
    func nestedAdjustmentsInOnePass() throws {
        let children = (0..<3_000).map { Spec(kind: .paragraph, text: "Строка \($0)", indent: 1) }
        let editor = try EditorFixture([Spec(kind: .quote, text: "Цитата")] + children)
        let textView = editor.textView
        let clock = ContinuousClock()
        let elapsed = clock.measure { textView.refreshBlockStructure() }
        #expect(elapsed < .milliseconds(150), "отступы 3 000 детей: \(elapsed)")
        let storage = try #require(textView.textStorage)
        let first = try #require(storage.attribute(.paragraphStyle, at: editor.textLocation(ofBlock: 1), effectiveRange: nil) as? NSParagraphStyle)
        let last = try #require(storage.attribute(.paragraphStyle, at: editor.textLocation(ofBlock: 3_000), effectiveRange: nil) as? NSParagraphStyle)
        #expect(last.headIndent == first.headIndent && first.headIndent > 0, "дети цитаты сдвинуты одинаково")
    }
}
