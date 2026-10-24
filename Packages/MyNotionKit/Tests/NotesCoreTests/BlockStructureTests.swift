import Foundation
import Testing
@testable import NotesCore

/// Правила вложенности и перестановки блоков без окна (005, research R4): те же проверки, что у редактора
/// (`PageEditorTests/BlockStructureTests`: Tab, ⇧Tab, ⌥⇧↑↓, перетаскивание «⋮⋮»), но на чистых функциях.
/// Окно и команда `mynotion` пользуются одними и теми же правилами.
@Suite("Правила структуры блоков")
struct BlockStructureTests {
    let pageId = UUID.timeOrdered()

    /// Блоки страницы по порядку: вид, текст, вложенность.
    func page(_ specs: [(BlockKind, String, Int)]) -> [Block] {
        var key: FractionalSortKey?
        return specs.map { kind, text, indent in
            key = .between(key, nil)
            return Block(pageId: pageId, kind: kind, text: InlineText(text), indent: indent, sortKey: key!)
        }
    }

    func bullets(_ texts: [String]) -> [Block] {
        page(texts.map { (.bulletItem, $0, 0) })
    }

    /// А с двумя вложенными, Б с одним вложенным, В.
    var nestedPage: [Block] {
        page([(.bulletItem, "А", 0), (.bulletItem, "а1", 1), (.bulletItem, "а2", 1), (.bulletItem, "Б", 0), (.bulletItem, "б1", 1),
              (.paragraph, "В", 0)])
    }

    /// Страница после правки: блоки отрезка заменены черновиками.
    func applied(_ blocks: [Block], _ change: (range: Range<Int>, drafts: [BlockDraft])?) -> [BlockDraft] {
        guard let change else { return blocks.map(BlockDraft.init) }
        var drafts = blocks.map(BlockDraft.init)
        drafts.replaceSubrange(change.range, with: change.drafts)
        return drafts
    }

    func texts(_ drafts: [BlockDraft]) -> [String] { drafts.map(\.text.string) }
    func indents(_ drafts: [BlockDraft]) -> [Int] { drafts.map(\.indent) }

    // MARK: Вложенность

    @Test("Tab вкладывает пункт не глубже соседа сверху + 1, ⇧Tab вынимает")
    func indentsWithinPreviousLevel() {
        var blocks = page([(.bulletItem, "один", 0), (.bulletItem, "два", 0), (.checkbox, "три", 0)])

        for _ in 1...2 {
            blocks = rebuilt(blocks, BlockStructure.indenting(blocks, selected: 1..<2, delta: 1))
        }
        #expect(blocks.map(\.indent) == [0, 1, 0], "Глубже соседа сверху + 1 не вкладывается")

        for _ in 1...2 {
            blocks = rebuilt(blocks, BlockStructure.indenting(blocks, selected: 2..<3, delta: 1))
        }
        #expect(blocks.map(\.indent) == [0, 1, 2])

        blocks = rebuilt(blocks, BlockStructure.indenting(blocks, selected: 2..<3, delta: -1))
        #expect(blocks.map(\.indent) == [0, 1, 1])
        #expect(blocks.map(\.text.string) == ["один", "два", "три"])
    }

    /// Блоки после правки с теми же id и видами.
    func rebuilt(_ blocks: [Block], _ change: (range: Range<Int>, drafts: [BlockDraft])?) -> [Block] {
        guard let change else { return blocks }
        var result = blocks
        for (offset, draft) in change.drafts.enumerated() {
            var block = blocks[change.range.lowerBound + offset]
            block.indent = draft.indent
            result[change.range.lowerBound + offset] = block
        }
        return result
    }

    @Test("Вложенность в пределах 0…8")
    func indentStaysWithinRange() {
        var blocks = page((0...8).map { (.bulletItem, "пункт \($0)", $0) } + [(.bulletItem, "последний", 8)])
        #expect(BlockStructure.indenting(blocks, selected: 9..<10, delta: 1) == nil, "Глубже 8 не вкладывается")

        #expect(BlockStructure.indenting(blocks, selected: 0..<1, delta: -1) == nil, "Выше 0 не вынимается")
        #expect(BlockStructure.indenting(blocks, selected: 0..<1, delta: 1) == nil, "Первому блоку не во что вкладываться")
        blocks[9].indent = 7
        #expect(BlockStructure.indenting(blocks, selected: 9..<10, delta: 1)?.drafts.map(\.indent) == [8])
    }

    @Test("Заголовок всегда на уровне 0, кроме как внутри переключателя, выноски, цитаты")
    func headingIndentsOnlyInsideContainers() {
        let plain = page([(.bulletItem, "пункт", 0), (.heading2, "Заголовок", 0)])
        #expect(BlockStructure.indenting(plain, selected: 1..<2, delta: 1) == nil)

        let inToggle = page([(.toggle, "список", 0), (.heading2, "Заголовок", 0)])
        #expect(BlockStructure.indenting(inToggle, selected: 1..<2, delta: 1)?.drafts.map(\.indent) == [1])

        #expect(BlockStructure.headingIndent(3, under: [(0, .bulletItem), (1, .bulletItem)]) == 0)
        #expect(BlockStructure.headingIndent(1, under: [(0, .callout)]) == 1)
        #expect(BlockStructure.headingIndent(5, at: 1, in: page([(.quote, "цитата", 0), (.heading1, "З", 3)])) == 1)
    }

    @Test("Tab с выделением через несколько пунктов вкладывает все")
    func indentsSelectedBlocks() {
        let blocks = bullets(["а", "бб", "вв"])
        let change = BlockStructure.indenting(blocks, selected: 1..<3, delta: 1)
        #expect(change?.range == 1..<3)
        #expect(change?.drafts.map(\.indent) == [1, 1])
    }

    @Test("Вложенные под последним выделенным сдвигаются вместе с ним")
    func indentCarriesNestedItems() {
        let blocks = nestedPage
        let change = BlockStructure.indenting(blocks, selected: 3..<4, delta: -1)
        #expect(change == nil, "Блок уже на уровне 0")

        let shifted = BlockStructure.indenting(blocks, selected: 0..<1, delta: 1)
        #expect(shifted == nil, "Первому блоку не во что вкладываться")

        let moved = BlockStructure.indenting(blocks, selected: 3..<4, delta: 1)
        #expect(moved?.range == 3..<5)
        #expect(moved?.drafts.map(\.indent) == [1, 2])
    }

    // MARK: Конец поддерева и группа

    @Test("Вложенные пункты едут вместе с пунктом")
    func subtreeEndIncludesNested() {
        let blocks = nestedPage
        #expect(BlockStructure.subtreeEnd(blocks, of: 0) == 3)
        #expect(BlockStructure.subtreeEnd(blocks, of: 1) == 2)
        #expect(BlockStructure.subtreeEnd(blocks, of: 3) == 5)
        #expect(BlockStructure.subtreeEnd(blocks, of: 5) == 6)
        #expect(BlockStructure.movedGroup(blocks, selected: 0..<1) == 0..<3)
        #expect(BlockStructure.movedGroup(blocks, selected: 0..<0) == 0..<0)
    }

    // MARK: Перестановка

    @Test("Блок переставляется на одно место выше и ниже; выше первого места не уходит")
    func moveUpAndDown() {
        let blocks = page([(.paragraph, "А", 0), (.heading1, "Б", 0), (.bulletItem, "В", 0)])

        let up = BlockStructure.moving(blocks, selected: 2..<3, by: -1)
        #expect(up?.range == 1..<3)
        #expect(texts(applied(blocks, up)) == ["А", "В", "Б"])
        #expect(applied(blocks, up).map(\.kind) == [.paragraph, .bulletItem, .heading1])

        #expect(BlockStructure.moving(blocks, selected: 0..<1, by: -1) == nil)
        #expect(BlockStructure.moving(blocks, selected: 2..<3, by: 1) == nil)
        #expect(texts(applied(blocks, BlockStructure.moving(blocks, selected: 0..<1, by: 1))) == ["Б", "А", "В"])
    }

    @Test("Пункт переносится вместе с вложенными, через соседа с его вложенными")
    func moveCarriesNestedItems() {
        let blocks = nestedPage

        let down = BlockStructure.moving(blocks, selected: 0..<1, by: 1)
        #expect(texts(applied(blocks, down)) == ["Б", "б1", "А", "а1", "а2", "В"])
        #expect(indents(applied(blocks, down)) == [0, 1, 0, 1, 1, 0], "Вложенность едет вместе с пунктом")

        let up = BlockStructure.moving(blocks, selected: 3..<4, by: -1)
        #expect(texts(applied(blocks, up)) == ["Б", "б1", "А", "а1", "а2", "В"])
    }

    @Test("Вложенный пункт переставляется среди своих соседей")
    func nestedItemMovesAmongSiblings() {
        let blocks = nestedPage
        let change = BlockStructure.moving(blocks, selected: 2..<3, by: -1)
        #expect(texts(applied(blocks, change)) == ["А", "а2", "а1", "Б", "б1", "В"])
        #expect(indents(applied(blocks, change)) == [0, 1, 1, 0, 1, 0])
    }

    @Test("Перенос блока в зазор: вниз, вверх, в свои же вложенные нельзя")
    func moveToGap() {
        let blocks = nestedPage

        let down = BlockStructure.moving(blocks, blockAt: 0, toGap: 5)
        #expect(texts(applied(blocks, down)) == ["Б", "б1", "А", "а1", "а2", "В"])
        #expect(indents(applied(blocks, down)) == [0, 1, 0, 1, 1, 0])

        let up = BlockStructure.moving(blocks, blockAt: 3, toGap: 0)
        #expect(texts(applied(blocks, up)) == ["Б", "б1", "А", "а1", "а2", "В"])

        #expect(BlockStructure.moving(blocks, blockAt: 0, toGap: 2) == nil, "В свои же вложенные пункт не переносится")
        #expect(BlockStructure.moving(blocks, blockAt: 0, toGap: 0) == nil, "На своё же место — ничего")
        #expect(BlockStructure.moving(blocks, blockAt: 9, toGap: 0) == nil)

        let child = BlockStructure.moving(blocks, blockAt: 4, toGap: 6)
        #expect(texts(applied(blocks, child)) == ["А", "а1", "а2", "Б", "В", "б1"], "Вложенный пункт без своих вложенных едет один")
    }
}
