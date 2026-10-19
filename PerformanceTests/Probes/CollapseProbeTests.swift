import AppKit
import NotesCore
import PageEditor
import XCTest

/// Проба свёртывания (T003, research R1, R16): страница на 1 000 блоков, у одного блока 200 детей, они спрятаны
/// от раскладки. Набор рядом со свёрнутым — p95 ≤ 50 мс; ⌘Z/⇧⌘Z, ⇧+стрелки, ⌫ и выделение внутри скрытого —
/// в видимом окне, с перерисовкой после каждого шага: без падений и потерь.
/// Переключателя ещё нет (US1): родитель — пункт списка, скрытие от типа не зависит.
@MainActor
final class CollapseProbeTests: XCTestCase {
    static let parentIndex = 400
    static let childCount = 200
    static var firstAfter: Int { parentIndex + childCount + 1 }

    private func makeEditor() throws -> ProbeEditor {
        var specs: [ProbeEditor.Spec] = (0..<Self.parentIndex).map { .init(text: "Абзац \($0): обычный текст страницы, mixed with Latin words.") }
        specs.append(.init(kind: .bulletItem, text: "Родитель"))
        specs += (0..<Self.childCount).map { .init(kind: .bulletItem, text: "Ребёнок \($0)", indent: 1) }
        specs += (Self.firstAfter..<1_000).map { .init(text: "Абзац \($0): обычный текст страницы, mixed with Latin words.") }
        return try ProbeEditor(specs)
    }

    private func childIds(_ editor: ProbeEditor) -> Set<UUID> {
        Set(editor.document.blocks[(Self.parentIndex + 1)...(Self.parentIndex + Self.childCount)].map(\.id))
    }

    func testTypingNextToCollapsedWithinBudget() async throws {
        let editor = try makeEditor()
        defer { editor.close() }
        try await editor.settle()
        let children = childIds(editor)
        editor.placeCaret(editor.location(ofBlock: Self.parentIndex))
        let collapseMs = ProbeEditor.measure {
            editor.textView.setHiddenBlocks(children)
            editor.window.displayIfNeeded()
        }

        let parentEnd = editor.location(ofBlock: Self.parentIndex) + ("Родитель" as NSString).length
        editor.placeCaret(parentEnd)
        var samples = try await editor.type(100)
        editor.placeCaret(editor.location(ofBlock: Self.firstAfter))
        samples += try await editor.type(100)
        let expandMs = ProbeEditor.measure {
            editor.textView.setHiddenBlocks([])
            editor.window.displayIfNeeded()
        }

        let summary = """
            Набор рядом со свёрнутым (200 детей, 1 000 блоков): p95 \(ProbeEditor.format(ProbeEditor.p95(samples))) мс, \
            худший \(ProbeEditor.format(samples.max() ?? 0)) мс, \(samples.count) нажатий
            Проба: свернуть \(ProbeEditor.format(collapseMs)) мс, развернуть \(ProbeEditor.format(expandMs)) мс
            """
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertEqual(editor.document.blocks.count, 1_000)
        XCTAssertTrue(editor.document.blocks[Self.parentIndex].text.string.hasPrefix("Родитель"))
        XCTAssertEqual(editor.document.blocks[Self.parentIndex].text.string.count, "Родитель".count + 100)
        XCTAssertEqual(editor.document.blocks[Self.firstAfter].text.string.count, "Абзац \(Self.firstAfter): обычный текст страницы, mixed with Latin words.".count + 100)
        XCTAssertLessThanOrEqual(ProbeEditor.p95(samples), 50, "Набор рядом со свёрнутым: p95 больше 50 мс")
    }

    func testEditingAroundCollapsedLosesNothing() throws {
        let editor = try makeEditor()
        defer { editor.close() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.textView.fallbackUndoManager = undo
        func step(_ action: () -> Void) {
            undo.beginUndoGrouping()
            action()
            undo.endUndoGrouping()
            editor.window.displayIfNeeded()
        }
        func type(_ text: String) {
            for character in text {
                step { editor.textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            }
        }
        let texts = { editor.document.blocks.map(\.text.string) }
        let original = texts()

        editor.placeCaret(editor.location(ofBlock: 5) + 3)
        type("до")
        editor.textView.setHiddenBlocks(childIds(editor))
        editor.window.displayIfNeeded()
        editor.placeCaret(editor.location(ofBlock: Self.firstAfter))
        type("после")
        XCTAssertTrue(texts()[5].contains("до"))
        XCTAssertTrue(texts()[Self.firstAfter].hasPrefix("после"))
        for _ in 0..<7 { undo.undo(); editor.window.displayIfNeeded() }
        XCTAssertEqual(texts(), original, "⌘Z правок до и после свёртывания вернул не тот текст")
        for _ in 0..<7 { undo.redo(); editor.window.displayIfNeeded() }
        XCTAssertTrue(texts()[5].contains("до") && texts()[Self.firstAfter].hasPrefix("после"), "⇧⌘Z")
        for _ in 0..<7 { undo.undo() }

        // ⇧+стрелки через свёрнутое.
        let parentEnd = editor.location(ofBlock: Self.parentIndex) + ("Родитель" as NSString).length
        editor.placeCaret(parentEnd)
        step { editor.textView.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:))) }
        let down = editor.textView.selectedRange()
        XCTAssertGreaterThanOrEqual(NSMaxRange(down), editor.location(ofBlock: Self.firstAfter), "⇧↓ не перешагнул скрытое: \(down)")
        editor.placeCaret(editor.location(ofBlock: Self.firstAfter))
        step { editor.textView.doCommand(by: #selector(NSResponder.moveUpAndModifySelection(_:))) }
        XCTAssertLessThanOrEqual(editor.textView.selectedRange().location, editor.location(ofBlock: Self.parentIndex + 1))
        editor.placeCaret(parentEnd)
        step { editor.textView.doCommand(by: #selector(NSResponder.moveRight(_:))) }
        step { editor.textView.doCommand(by: #selector(NSResponder.moveRight(_:))) }
        step { editor.textView.doCommand(by: #selector(NSResponder.moveLeft(_:))) }

        // ⌫ в начале блока под свёрнутым: ничего не теряется, ⌘Z возвращает.
        editor.placeCaret(editor.location(ofBlock: Self.firstAfter))
        step { editor.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
        XCTAssertTrue(texts().joined().contains("Абзац \(Self.firstAfter):"))
        undo.undo()
        editor.window.displayIfNeeded()
        XCTAssertEqual(texts(), original)

        // Программное выделение внутри скрытого и набор туда.
        let hiddenLocation = editor.location(ofBlock: Self.parentIndex + 100) + 2
        editor.textView.setSelectedRange(NSRange(location: hiddenLocation, length: 5))
        editor.textView.scrollRangeToVisible(editor.textView.selectedRange())
        editor.window.displayIfNeeded()
        type("x")
        XCTAssertEqual(texts()[Self.parentIndex + 100], "Реx 99")
        undo.undo()
        editor.window.displayIfNeeded()
        XCTAssertEqual(texts(), original)
        XCTAssertEqual(editor.document.blocks.count, 1_000)
    }
}
