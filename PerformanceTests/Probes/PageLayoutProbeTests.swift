import AppKit
import NotesCore
import PageCover
import PageEditor
import XCTest

/// Проба вида страницы (T003, research R14, п. 1; US1 — с настоящей обложкой галереи): «богатая» страница 002 с обложкой 280;
/// «Мелкий шрифт» и «Широкая страница» туда и обратно. Перекладка ≤ 200 мс; после каждого шага снимок окна: ширина
/// строки и размер шрифта изменились, таблица, код и картинка нарисованы не пустыми; набор после переключений p95 ≤ 50 мс.
@MainActor
final class PageLayoutProbeTests: XCTestCase {
    static let switchBudgetMs = 200.0
    static let typingBudgetMs = 50.0
    /// Доля «нарисованных» пикселей в рамке вида 002, ниже которой вид считается пустым.
    static let minimumInk = 0.02

    func testLayoutSwitchesRelayoutQuicklyAndKeepViewsDrawn() async throws {
        let page = try RichProbePage()
        defer { page.close() }
        let cover = CoverView(cover: PageCover(source: .gallery("gradients_5")), fileURL: { _ in nil })
        page.textView.setCover(cover, height: 280) { [weak cover] left, width in cover?.setColumn(left: left, width: width) }
        try await page.settle()

        let paragraphIndex = try XCTUnwrap(page.textView.document.blocks.firstIndex { $0.kind == .paragraph })
        let steps: [(name: String, settings: PageLayoutSettings)] = [
            ("1-обычная", PageLayoutSettings()),
            ("2-мелкий", PageLayoutSettings(isSmallText: true)),
            ("3-мелкий-широкая", PageLayoutSettings(isFullWidth: true, isSmallText: true)),
            ("4-широкая", PageLayoutSettings(isFullWidth: true)),
            ("5-обычная", PageLayoutSettings()),
        ]
        var lines: [String] = []
        var switchMs: [Double] = []
        var previous: (width: CGFloat, font: CGFloat)?
        for (number, step) in steps.enumerated() {
            if number > 0 {
                // Перекладка видна у верха страницы: заглушка обложки, шапка, первые блоки.
                page.scroll(toBlock: 0)
                page.textView.scroll(.zero)
                let ms = ProbeEditor.measure {
                    page.textView.applyLayout(step.settings)
                    page.textView.layoutSubtreeIfNeeded()
                    page.window.displayIfNeeded()
                }
                switchMs.append(ms)
            }
            try await page.settle()
            let width = page.textView.textContainer?.size.width ?? 0
            let font = (page.textView.textStorage?.attribute(.font, at: page.location(ofBlock: paragraphIndex), effectiveRange: nil) as? NSFont)?.pointSize ?? 0
            if let previous, number > 0 {
                let before = steps[number - 1].settings, now = step.settings
                if before.isFullWidth != now.isFullWidth { XCTAssertNotEqual(previous.width, width, "\(step.name): ширина строки не поменялась") }
                if before.isSmallText != now.isSmallText { XCTAssertNotEqual(previous.font, font, "\(step.name): размер шрифта не поменялся") }
            }
            previous = (width, font)

            // Обложка и шапка у верха.
            page.textView.scroll(.zero)
            page.window.displayIfNeeded()
            var shots: [String] = []
            if let bitmap = page.snapshot() {
                let coverInk = page.inkFraction(of: cover, in: bitmap)
                XCTAssertGreaterThan(coverInk, 0.5, "\(step.name): обложка не нарисована")
                shots.append(page.save(bitmap, name: "layout-\(step.name)-top", to: self))
            }
            // Виды 002: таблица, код, картинка — каждый у верха окна, со снимком.
            var inks: [String] = []
            for (kind, className) in [(BlockKind.table, "TableView"), (.code, "CodeBlockView"), (.image, "ImageBlockView")] {
                let index = try XCTUnwrap(page.blockIndex(of: kind), "На странице нет блока \(kind)")
                page.scroll(toBlock: index)
                try await page.settle(150)
                let view = page.visibleSubview(named: className)
                XCTAssertNotNil(view, "\(step.name): вид \(className) не создан")
                guard let view, let bitmap = page.snapshot() else { continue }
                let ink = page.inkFraction(of: view, in: bitmap)
                inks.append("\(className) \(String(format: "%.0f", ink * 100)) %, ширина \(Int(view.frame.width))")
                XCTAssertGreaterThan(ink, Self.minimumInk, "\(step.name): вид \(className) пустой")
                shots.append(page.save(bitmap, name: "layout-\(step.name)-\(className)", to: self))
            }
            lines.append("Проба вида: \(step.name) — строка \(Int(width)), шрифт абзаца \(ProbeEditor.format(font)); \(inks.joined(separator: "; "))")
            lines.append("Снимок: \(shots.joined(separator: ", "))")
        }

        // Набор после переключений: мелкий шрифт и широкая включены.
        page.textView.applyLayout(PageLayoutSettings(isFullWidth: true, isSmallText: true))
        page.scroll(toBlock: paragraphIndex)
        let caret = page.location(ofBlock: paragraphIndex)
        page.textView.setSelectedRange(NSRange(location: caret, length: 0))
        try await page.settle()
        var typing: [Double] = []
        let characters = Array("быстрый набор text ")
        for index in 0..<100 {
            typing.append(ProbeEditor.measure {
                page.textView.insertText(String(characters[index % characters.count]), replacementRange: NSRange(location: NSNotFound, length: 0))
                page.window.displayIfNeeded()
            })
            try await Task.sleep(for: .milliseconds(10))
        }

        // Для US1 — справочно: полная перерисовка текста вместо правки атрибутов на месте.
        let summary = ([
            "Проба вида: перекладка «Мелкий шрифт» / «Широкая» — \(switchMs.map(ProbeEditor.format).joined(separator: ", ")) мс, худшая \(ProbeEditor.format(switchMs.max() ?? 0)) мс (предел 200)",
            "Проба вида: набор после переключений (мелкий и широкая) p95 \(ProbeEditor.format(ProbeEditor.p95(typing))) мс, худший \(ProbeEditor.format(typing.max() ?? 0)) мс",
        ] + lines).joined(separator: "\n")
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertLessThanOrEqual(switchMs.max() ?? .infinity, Self.switchBudgetMs, "Перекладка вида дольше 200 мс")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(typing), Self.typingBudgetMs, "Набор после переключения: p95 больше 50 мс")
    }
}
