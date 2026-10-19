import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// Скрытие абзацев от раскладки (research R1, проба T003): страница на 1 000 блоков, под блоком 10 — 200 детей.
/// Переключателя ещё нет (он появится в US1), поэтому родитель — пункт списка: само скрытие от типа не зависит.
@MainActor
@Suite("Скрытые абзацы")
struct HiddenParagraphsTests {
    static let parentIndex = 10
    static let childCount = 200
    static var firstAfter: Int { parentIndex + childCount + 1 }

    static func makeFixture() throws -> EditorFixture {
        var specs: [EditorFixture.Spec] = (0..<parentIndex).map { .paragraph("Абзац \($0)") }
        specs.append(.bullet("Родитель"))
        specs += (0..<childCount).map { .bullet("Ребёнок \($0)", indent: 1) }
        specs += (firstAfter..<1_000).map { .paragraph("Абзац \($0)") }
        let fixture = try EditorFixture(specs)
        fixture.textView.textLayoutManager?.ensureLayout(for: fixture.textView.textLayoutManager!.documentRange)
        return fixture
    }

    static func childIds(_ fixture: EditorFixture) -> Set<UUID> {
        Set(fixture.document.blocks[(parentIndex + 1)...(parentIndex + childCount)].map(\.id))
    }

    /// Низ последнего абзаца страницы.
    static func layoutHeight(_ fixture: EditorFixture) -> CGFloat {
        let layoutManager = fixture.textView.textLayoutManager!
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var bottom: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.endLocation, options: [.reverse, .ensuresLayout]) {
            bottom = $0.layoutFragmentFrame.maxY
            return false
        }
        return bottom
    }

    static func fragmentFrame(_ fixture: EditorFixture, block index: Int) -> CGRect {
        let layoutManager = fixture.textView.textLayoutManager!
        let storage = fixture.textView.textContentStorage!
        let location = storage.location(storage.documentRange.location, offsetBy: fixture.textLocation(ofBlock: index))!
        return layoutManager.textLayoutFragment(for: location)?.layoutFragmentFrame ?? .null
    }

    /// Абзацы, у которых есть фрагмент раскладки.
    static func laidOutBlockIds(_ fixture: EditorFixture) -> Set<UUID> {
        let layoutManager = fixture.textView.textLayoutManager!
        var ids: Set<UUID> = []
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let paragraph = fragment.textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
               let id = paragraph.attributedString.attribute(.blockID, at: 0, effectiveRange: nil) as? UUID {
                ids.insert(id)
            }
            return true
        }
        return ids
    }

    @Test("Спрятанные абзацы не раскладываются, высота страницы уменьшается; открытие возвращает всё")
    func hiddenParagraphsHaveNoLayout() throws {
        let fixture = try Self.makeFixture()
        let fullHeight = Self.layoutHeight(fixture)
        let children = Self.childIds(fixture)

        fixture.textView.hiddenParagraphs.setHiddenBlocks(children)
        let laidOut = Self.laidOutBlockIds(fixture)
        #expect(laidOut.isDisjoint(with: children))
        #expect(laidOut.count == 1_000 - Self.childCount)
        let collapsedHeight = Self.layoutHeight(fixture)
        let parentFrame = Self.fragmentFrame(fixture, block: Self.parentIndex)
        let afterFrame = Self.fragmentFrame(fixture, block: Self.firstAfter)
        #expect(afterFrame.minY - parentFrame.maxY < 20, "под родителем сразу следующий видимый: \(parentFrame) \(afterFrame)")
        #expect(collapsedHeight < fullHeight - CGFloat(Self.childCount) * 20)
        #expect(fixture.texts.count == 1_000, "текст страницы и документ не меняются")

        fixture.textView.hiddenParagraphs.setHiddenBlocks([])
        #expect(Self.laidOutBlockIds(fixture).count == 1_000)
        #expect(abs(Self.layoutHeight(fixture) - fullHeight) < 1)
    }

    @Test("Набор до и после скрытого: текст в своих блоках, ⌘Z и ⇧⌘Z возвращают нужное")
    func typingAndUndoAroundHidden() throws {
        let fixture = try Self.makeFixture()
        // Правка до свёртывания.
        fixture.placeCaret(inBlock: 5, at: nil)
        fixture.type("до")
        fixture.textView.hiddenParagraphs.setHiddenBlocks(Self.childIds(fixture))
        // Правки после свёртывания — над скрытым и под ним.
        fixture.placeCaret(inBlock: Self.parentIndex, at: nil)
        fixture.type("Р")
        fixture.placeCaret(inBlock: Self.firstAfter, at: nil)
        fixture.type("П")
        #expect(fixture.texts[5] == "Абзац 5до")
        #expect(fixture.texts[Self.parentIndex] == "РодительР")
        #expect(fixture.texts[Self.firstAfter] == "Абзац \(Self.firstAfter)П")

        for _ in 0..<4 { fixture.undo() }
        #expect(fixture.texts[5] == "Абзац 5")
        #expect(fixture.texts[Self.parentIndex] == "Родитель")
        #expect(fixture.texts[Self.firstAfter] == "Абзац \(Self.firstAfter)")
        for _ in 0..<4 { fixture.redo() }
        #expect(fixture.texts[5] == "Абзац 5до")
        #expect(fixture.texts[Self.parentIndex] == "РодительР")
        #expect(fixture.texts[Self.firstAfter] == "Абзац \(Self.firstAfter)П")
        #expect(fixture.texts.count == 1_000)
        #expect(Set(fixture.texts[(Self.parentIndex + 1)...(Self.parentIndex + Self.childCount)]).count == Self.childCount)
    }

    @Test("⇧+стрелки через скрытое: выделение перешагивает детей и захватывает их, без падений")
    func shiftArrowsAcrossHidden() throws {
        let fixture = try Self.makeFixture()
        fixture.textView.hiddenParagraphs.setHiddenBlocks(Self.childIds(fixture))
        fixture.placeCaret(inBlock: Self.parentIndex, at: nil)
        fixture.press(#selector(NSResponder.moveDownAndModifySelection(_:)))
        let down = fixture.textView.selectedRange()
        let afterStart = fixture.textLocation(ofBlock: Self.firstAfter)
        #expect(NSMaxRange(down) >= afterStart, "выделение вниз ушло за скрытых детей: \(down), начало следующего \(afterStart)")

        fixture.placeCaret(inBlock: Self.firstAfter, at: 0)
        fixture.press(#selector(NSResponder.moveUpAndModifySelection(_:)))
        let up = fixture.textView.selectedRange()
        #expect(up.location <= fixture.textLocation(ofBlock: Self.parentIndex + 1), "выделение вверх: \(up)")

        fixture.placeCaret(inBlock: Self.parentIndex, at: nil)
        fixture.press(#selector(NSResponder.moveRightAndModifySelection(_:)))
        fixture.press(#selector(NSResponder.moveRightAndModifySelection(_:)))
        #expect(fixture.textView.selectedRange().length > 0)
        #expect(fixture.texts.count == 1_000)
    }

    @Test("⌫ в начале блока под скрытым: текст не теряется (склейку с родителем делает US1)")
    func backspaceUnderHidden() throws {
        let fixture = try Self.makeFixture()
        fixture.textView.hiddenParagraphs.setHiddenBlocks(Self.childIds(fixture))
        fixture.placeCaret(inBlock: Self.firstAfter, at: 0)
        fixture.press(#selector(NSResponder.deleteBackward(_:)))
        let joined = fixture.texts.joined(separator: "\n")
        #expect(joined.contains("Абзац \(Self.firstAfter)"))
        #expect(joined.contains("Ребёнок \(Self.childCount - 1)"))
        fixture.undo()
        #expect(fixture.texts.count == 1_000)
        #expect(fixture.texts[Self.firstAfter] == "Абзац \(Self.firstAfter)")
    }

    @Test("Выделение внутри скрытого и набор туда: без падений и потерь")
    func selectionInsideHidden() throws {
        let fixture = try Self.makeFixture()
        fixture.textView.hiddenParagraphs.setHiddenBlocks(Self.childIds(fixture))
        fixture.placeCaret(inBlock: Self.parentIndex + 100, at: 3)
        fixture.textView.window?.displayIfNeeded()
        _ = fixture.textView.firstRect(forCharacterRange: fixture.textView.selectedRange(), actualRange: nil)
        fixture.select(inBlock: Self.parentIndex + 50, "Ребёнок")
        fixture.textView.window?.displayIfNeeded()
        fixture.type("x")
        #expect(fixture.texts[Self.parentIndex + 50] == "x 49")
        fixture.undo()
        #expect(fixture.texts[Self.parentIndex + 50] == "Ребёнок 49")
    }
}
