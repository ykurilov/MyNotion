import AppKit
import Testing
@testable import PageEditor
import VisualStyle

/// Промежутки вокруг заголовков как в Notion (ui-review 15.10.2026, № 3): от верха прописных букв абзаца до верха
/// прописных букв заголовка и от заголовка до абзаца под ним. Замер Notion 7.38.1 по снимку `top-light`
/// (0,83 px/pt, точность ±1,2): абзац → H1 67, H1 → абзац 53, абзац → H2 60, H2 → абзац 47, абзац → H3 55, H3 → абзац 42.
@MainActor
@Suite("Отступы вокруг заголовков как в Notion")
struct HeadingSpacingTests {
    struct Gap: CustomTestStringConvertible, Sendable {
        let level: Int
        let before: CGFloat
        let after: CGFloat
        var testDescription: String { "H\(level)" }
    }

    nonisolated static let notion = [Gap(level: 1, before: 67.2, after: 52.8), Gap(level: 2, before: 60, after: 46.8), Gap(level: 3, before: 55.2, after: 42)]

    /// Верх прописных букв первой строки блока.
    private func capTop(ofBlock index: Int, in editor: EditorFixture) throws -> CGFloat {
        let line = try #require(editor.textView.markerLine(ofBlockAt: index))
        let kind = editor.document.blocks[index].kind
        let font = Typography.line(for: PageTextStorageMapper.textStyle(of: kind)).font
        return line.baseline - font.capHeight
    }

    @Test("Абзац → заголовок → абзац: промежутки Notion ±1,5", arguments: Self.notion)
    func gapsAroundHeading(_ gap: Gap) throws {
        let editor = try EditorFixture([.paragraph("Абзац над заголовком"), .heading(gap.level, "Заголовок"), .paragraph("Абзац под заголовком")])
        let above = try capTop(ofBlock: 0, in: editor)
        let heading = try capTop(ofBlock: 1, in: editor)
        let below = try capTop(ofBlock: 2, in: editor)
        #expect(abs(heading - above - gap.before) <= 1.5, "H\(gap.level): над заголовком \(heading - above), у Notion \(gap.before)")
        #expect(abs(below - heading - gap.after) <= 1.5, "H\(gap.level): под заголовком \(below - heading), у Notion \(gap.after)")
    }
}
