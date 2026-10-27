import Foundation
import NotesCore
import Testing
@testable import PageMarkdown

@Suite("Вставка: формулы в ячейках таблицы")
struct PastedTableFormulaTests {
    private func cells(_ tableHTML: String) -> [Block] {
        let blocks = PastedText.blocks(from: "x\ny", html: "<h3>Заголовок</h3>" + tableHTML, pageId: UUID(), hasRichText: true)
        return (blocks ?? []).filter { $0.kind == .tableCell }
    }

    @Test("Знаки − ÷ × из названий сущностей остаются в ячейке целиком")
    func mathEntities() {
        let cells = cells("<table><tr><th>A</th><th>B</th></tr><tr><td>ROI</td><td>(Доход &minus; инвестиции) &divide; инвестиции &times; 100%</td></tr></table>")
        #expect(cells.last?.text.string == "(Доход − инвестиции) ÷ инвестиции × 100%")
    }

    @Test("Формула KaTeX из чата — одна формула, а не три копии текста")
    func katexFormula() {
        let katex = """
        <span class="katex"><span class="katex-mathml"><math><semantics><mrow><mi>a</mi><mo>+</mo><mi>b</mi></mrow>\
        <annotation encoding="application/x-tex">a + b</annotation></semantics></math></span>\
        <span class="katex-html" aria-hidden="true"><span class="mord">a</span><span class="mbin">+</span><span class="mord">b</span></span></span>
        """
        let cells = cells("<table><tr><th>A</th><th>B</th></tr><tr><td>ROI</td><td>\(katex) × 100%</td></tr></table>")
        let formula = try? #require(cells.last)
        #expect(formula?.text.runs.contains { $0.style == .equation("a + b") } == true)
        #expect(formula?.text.string.hasSuffix(" × 100%") == true)
        #expect(formula?.text.string.contains("a+b") == false)
    }
}
