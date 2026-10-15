import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Шаг между базовыми линиями соседних блоков (ui-review 15.10.2026, № 19): между абзацем и списком,
/// чекбоксом или подстраницей у Notion ≈ 39–40, внутри списка и между абзацами — 30.
@MainActor
@Suite("Шаг между абзацем и списком")
struct BlockGroupSpacingTests {
    typealias Spec = EditorFixture.Spec

    private func steps(in editor: EditorFixture) throws -> [CGFloat] {
        // Курсор в последний блок: раскладка устоялась.
        editor.placeCaret(inBlock: editor.document.blocks.count - 1)
        let baselines = try editor.document.blocks.indices.map { try #require(editor.textView.markerLine(ofBlockAt: $0)).baseline }
        return zip(baselines.dropFirst(), baselines).map { $0 - $1 }
    }

    static let regular = Metrics.block(.paragraph).height
    static let between = Metrics.block(.paragraph).height + Metrics.Page.paragraphListSpacing

    @Test("Абзац → пункт ≈ 40, пункт → пункт 30, пункт → абзац ≈ 40, абзац → подстраница ≈ 40, абзац → абзац 30")
    func stepsMatchNotion() throws {
        let editor = try EditorFixture([.paragraph("Абзац"), .bullet("Пункт"), .checkbox("Задача", indent: 1), .paragraph("Последний абзац"),
                                        Spec(kind: .pageLink, link: UUID()), .paragraph("После"), .paragraph("Ещё")])
        let measured = try steps(in: editor)
        let expected = [Self.between, Self.regular, Self.between, Self.between, Self.between, Self.regular]
        #expect(abs(Self.between - 39.5) <= 1, "Шаг абзац ↔ список \(Self.between), у Notion ≈ 39–40")
        for (index, (step, want)) in zip(measured, expected).enumerated() {
            #expect(abs(step - want) < 0.5, "Шаг \(index) → \(index + 1): \(step), нужно \(want); все шаги \(measured)")
        }
    }

    @Test("Смена типа блока меняет шаг до соседей")
    func kindChangeUpdatesNeighbours() throws {
        let editor = try EditorFixture([.paragraph("Один"), .paragraph("Два"), .paragraph("Три")])
        editor.placeCaret(inBlock: 1)
        editor.perform(.setKind(.bulletItem))
        var measured = try steps(in: editor)
        #expect(abs(measured[0] - Self.between) < 0.5 && abs(measured[1] - Self.between) < 0.5, "После смены на пункт: \(measured)")

        editor.placeCaret(inBlock: 1)
        editor.perform(.setKind(.paragraph))
        measured = try steps(in: editor)
        #expect(abs(measured[0] - Self.regular) < 0.5 && abs(measured[1] - Self.regular) < 0.5, "Снова абзац: \(measured)")
    }

    @Test("Enter в конце пункта и ⌫ пустого пункта: шаг до абзаца ниже пересчитывается")
    func typingUpdatesNeighbours() throws {
        let editor = try EditorFixture([.bullet("Пункт"), .paragraph("Абзац")])
        editor.placeCaret(inBlock: 0, at: nil)
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(editor.kinds == [.bulletItem, .bulletItem, .paragraph])
        var measured = try steps(in: editor)
        #expect(abs(measured[0] - Self.regular) < 0.5 && abs(measured[1] - Self.between) < 0.5, "Новый пункт: \(measured)")

        editor.undo()
        measured = try steps(in: editor)
        #expect(editor.kinds == [.bulletItem, .paragraph])
        #expect(abs(measured[0] - Self.between) < 0.5, "После отмены: \(measured)")
    }
}
