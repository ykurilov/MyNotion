import Foundation
import Testing
@testable import NotesCore

/// Раздел заголовка — что прячет свёрнутый заголовок: блоки после него до заголовка того же или более крупного уровня
/// на той же глубине, до выхода из родителя или до конца потока; вложенное в них — вместе с ними.
@Suite("Раздел заголовка")
struct HeadingSectionsTests {
    static func blocks(_ specs: [(BlockKind, Int)]) -> [Block] {
        let pageId = UUID()
        var key: FractionalSortKey?
        return specs.map { kind, indent in
            key = .between(key, nil)
            return Block(pageId: pageId, kind: kind, indent: indent, sortKey: key!)
        }
    }

    @Test("H2 прячет свои H3 и текст до следующего H2")
    func headingTwoStopsAtSameLevel() {
        let blocks = Self.blocks([(.heading2, 0), (.paragraph, 0), (.heading3, 0), (.paragraph, 0), (.heading2, 0), (.paragraph, 0)])
        #expect(HeadingSections.sectionEnd(blocks, ofHeadingAt: 0) == 4)
        #expect(HeadingSections.foldedCount(blocks, ofHeadingAt: 0) == 3)
    }

    @Test("H2 кончается и на H1; H1 прячет всё до следующего H1")
    func largerHeadingEndsSection() {
        let blocks = Self.blocks([(.heading1, 0), (.heading2, 0), (.paragraph, 0), (.heading1, 0), (.paragraph, 0)])
        #expect(HeadingSections.sectionEnd(blocks, ofHeadingAt: 1) == 3)
        #expect(HeadingSections.sectionEnd(blocks, ofHeadingAt: 0) == 3)
    }

    @Test("Без следующего заголовка раздел идёт до конца потока; у заголовка в конце раздел пуст")
    func sectionRunsToEnd() {
        let blocks = Self.blocks([(.heading3, 0), (.paragraph, 0), (.heading3, 0)])
        #expect(HeadingSections.sectionEnd(blocks, ofHeadingAt: 2) == 3)
        #expect(HeadingSections.foldedCount(blocks, ofHeadingAt: 2) == 0)
        let open = Self.blocks([(.heading1, 0), (.paragraph, 0), (.heading2, 0), (.heading3, 0)])
        #expect(HeadingSections.sectionEnd(open, ofHeadingAt: 0) == 4)
    }

    @Test("Вложенное в спрятанные блоки — в разделе, но не в счёте; заголовок внутри переключателя раздел не кончает")
    func nestedBlocksGoWithParents() {
        let blocks = Self.blocks([(.heading2, 0), (.toggle, 0), (.paragraph, 1), (.heading1, 1), (.bulletItem, 0), (.bulletItem, 1),
                                  (.heading2, 0)])
        #expect(HeadingSections.sectionEnd(blocks, ofHeadingAt: 0) == 6)
        #expect(HeadingSections.foldedCount(blocks, ofHeadingAt: 0) == 2, "переключатель и пункт; их дети не считаются")
    }

    @Test("Заголовок внутри переключателя прячет только блоки этого переключателя")
    func headingInsideToggleStopsAtParentEnd() {
        let blocks = Self.blocks([(.toggle, 0), (.heading2, 1), (.paragraph, 1), (.paragraph, 2), (.paragraph, 0)])
        #expect(HeadingSections.sectionEnd(blocks, ofHeadingAt: 1) == 4)
        #expect(HeadingSections.foldedCount(blocks, ofHeadingAt: 1) == 1)
    }

    @Test("Подпись свёрнутого: «…1 блок», «…2 блока», «…5 блоков» и остальные окончания")
    func foldedLabelWording() {
        let cases: [(Int, String)] = [(1, "…1 блок"), (2, "…2 блока"), (4, "…4 блока"), (5, "…5 блоков"), (11, "…11 блоков"),
                                      (12, "…12 блоков"), (14, "…14 блоков"), (21, "…21 блок"), (22, "…22 блока"),
                                      (25, "…25 блоков"), (101, "…101 блок"), (111, "…111 блоков"), (112, "…112 блоков")]
        for (count, label) in cases {
            #expect(HeadingSections.foldedLabel(count: count) == label)
        }
    }
}
