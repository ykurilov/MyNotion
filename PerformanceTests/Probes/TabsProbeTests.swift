import AppKit
import NotesCore
import PageEditor
import XCTest

/// Проба вкладок (T004, research R14, п. 2): 20 вкладок, переключение по кругу через заглушку модели вкладок —
/// неактивная вкладка держит только id страницы и место прокрутки (блок у верха и сдвиг), редактор один на окно (R5).
/// p95 ≤ 50 мс; после 100 переключений живой ровно один редактор страницы; прирост памяти ≤ 5 МБ; место прокрутки
/// вернулось. Меряется на 20 «богатых» страницах 002 и, для сравнения с переходом 001, на 20 страницах по 1 000 блоков текста.
@MainActor
final class TabsProbeTests: XCTestCase {
    static let tabCount = 20
    static let switchCount = 100
    static let budgetMs = 50.0
    static let memoryBudgetMB = 5.0

    /// Заглушка вкладки: страница и место прокрутки.
    struct ProbeTab {
        let pageId: UUID
        var anchor: (block: Int, offset: CGFloat)
    }

    struct Round {
        var total: [Double] = []
        var totalCPU: [Double] = []
        var open: [Double] = []
        var restore: [Double] = []
        var memoryBefore = 0.0, memoryHalfway = 0.0, memoryAfter = 0.0
        var liveEditors = 0
        var allEditors = 0
        var scrollMismatches: [String] = []
    }

    func testTwentyRichTabsSwitchQuicklyWithOneEditor() throws {
        let page = try RichProbePage()
        defer { page.close() }
        let round = try run(page, sourcePageId: page.pageId, label: "«богатых»")
        let shots = try checkReturnSnapshot(page, label: "rich")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(round.total), Self.budgetMs, "Переключение вкладки «богатых» страниц: p95 больше 50 мс")
        assertRound(round)
        XCTAssertTrue(shots, "Снимки до ухода и после возврата различаются")
    }

    func testTwentyTextTabsSwitchQuicklyWithOneEditor() throws {
        let page = try RichProbePage()
        defer { page.close() }
        // Страница по 1 000 блоков текста 001 (заполнение «богатой» страницы без частей 002).
        let textPage = try page.store.write { tx -> UUID in
            var created = try tx.createPage(title: "Текст 1 000")
            created = try tx.updatePage(created)
            for block in try tx.blocks(ofPage: created.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            for index in 0..<1_000 {
                key = .between(key, nil)
                let spec = RichPageGenerator.filler(index)
                try tx.insertBlock(Block(pageId: created.id, kind: spec.kind, text: spec.text, indent: spec.indent, sortKey: key!, color: spec.color))
            }
            return created.id
        }
        let round = try run(page, sourcePageId: textPage, label: "текстовых")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(round.total), Self.budgetMs, "Переключение вкладки текстовых страниц: p95 больше 50 мс")
        assertRound(round)
    }

    private func assertRound(_ round: Round) {
        XCTAssertEqual(round.liveEditors, 1, "Живых редакторов страницы больше одного")
        XCTAssertLessThanOrEqual(round.memoryAfter - round.memoryBefore, Self.memoryBudgetMB, "Прирост памяти больше 5 МБ")
        XCTAssertTrue(round.scrollMismatches.isEmpty, "Место прокрутки не вернулось: \(round.scrollMismatches.prefix(3))")
    }

    /// 20 вкладок — копии `sourcePageId` с новыми id; круг прогрева, затем 100 переключений.
    private func run(_ page: RichProbePage, sourcePageId: UUID, label: String) throws -> Round {
        var tabs: [ProbeTab] = []
        for number in 1...Self.tabCount {
            let id = number == 1 ? sourcePageId : try BranchCopyDraft.copy(sourcePageId, in: page.store)
            tabs.append(ProbeTab(pageId: id, anchor: (40 + number * 37, 0)))
        }
        var active = -1
        var round = Round()
        func switchTo(_ index: Int, record: Bool) throws {
            try autoreleasepool {
                if active >= 0 {
                    tabs[active].anchor = page.scrollAnchor()
                    page.rememberTop(for: tabs[active].anchor)
                }
                active = index
                let opened = try ProbeEditor.measureCPU {
                    page.show(try RichProbePage.editor(for: tabs[index].pageId, in: page.store))
                    page.window.displayIfNeeded()
                }
                let restored = ProbeEditor.measureCPU { page.restore(tabs[index].anchor) }
                let open = opened.wall, restore = restored.wall
                // Ход цикла событий в том же пуле: отложенная раскладка и виды, как в окне.
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
                if record {
                    round.open.append(open)
                    round.restore.append(restore)
                    round.total.append(open + restore)
                    round.totalCPU.append(opened.cpu + restored.cpu)
                }
            }
        }

        // Круг прогрева: шрифты, подсветка кода, кеши TextKit; места прокрутки встают на свои блоки.
        for index in 0..<Self.tabCount { try switchTo(index, record: false) }
        try switchTo(0, record: false)
        for _ in 0..<5 { page.pump(100) }
        round.memoryBefore = RichProbePage.heapAllocatedMB()

        var memoryHalfway = 0.0
        for step in 1...Self.switchCount {
            if step == Self.switchCount / 2 + 1 {
                for _ in 0..<5 { page.pump(100) }
                memoryHalfway = RichProbePage.heapAllocatedMB()
            }
            let target = step % Self.tabCount
            try autoreleasepool {
                let expected = tabs[target].anchor
                let expectedY = page.blockTopAfterRestore(of: expected)
                try switchTo(target, record: true)
                page.pump(step % 10 == 0 ? 50 : 10)
                // Место: у верха тот же блок, что был при уходе (сдвиг внутри блока TextKit 2 уточняет по ходу раскладки).
                let nowBlock = page.topVisibleBlockIndex() ?? -1
                if nowBlock != expected.block {
                    round.scrollMismatches.append("вкладка \(target + 1): ждали блок \(expected.block), у верха \(nowBlock) (верх \(Int(page.textView.visibleRect.minY)), был \(Int(expectedY ?? -1)))")
                }
            }
        }
        page.textView.inputContext?.activate()
        for _ in 0..<5 { page.pump(100) }
        round.liveEditors = PageTextView.livePageEditorCount
        round.allEditors = PageTextView.liveEditorCount
        if round.liveEditors > 1 { RichPageLeakProbeTests.saveTraceTrees(of: ["PageTextView"], to: "trace-editors-\(label).txt") }
        round.memoryAfter = RichProbePage.heapAllocatedMB()
        round.memoryHalfway = memoryHalfway

        let summary = """
            Проба вкладок (\(label)): \(Self.switchCount) переключений по кругу 20 страниц — p95 \(ProbeEditor.format(ProbeEditor.p95(round.total))) мс, \
            медиана \(ProbeEditor.format(round.total.sorted()[round.total.count / 2])) мс, худшее \(ProbeEditor.format(round.total.max() ?? 0)) мс (предел 50); \
            время процессора медиана \(ProbeEditor.format(ProbeEditor.median(round.totalCPU))) мс, p95 \(ProbeEditor.format(ProbeEditor.p95(round.totalCPU))) мс; из них открытие p95 \(ProbeEditor.format(ProbeEditor.p95(round.open))) мс, возврат места p95 \(ProbeEditor.format(ProbeEditor.p95(round.restore))) мс
            Проба вкладок (\(label)): живых редакторов страницы \(round.liveEditors), всех с колонками и ячейками \(round.allEditors) \
            (на открытой странице \(page.textView.document.blocks.isEmpty ? 0 : Self.flowEditorsOnScreen(page))); занято в куче после прогрева / 50 / 100 переключений — \
            \(ProbeEditor.format(round.memoryBefore)) / \(ProbeEditor.format(round.memoryHalfway)) / \(ProbeEditor.format(round.memoryAfter)) МБ \
            (прирост \(ProbeEditor.format(round.memoryAfter - round.memoryBefore)), предел 5); \
            место прокрутки — расхождений \(round.scrollMismatches.count)
            """
        print(summary)
        add(XCTAttachment(string: summary + "\n" + round.scrollMismatches.prefix(10).joined(separator: "\n")))
        return round
    }

    /// Место прокрутки на снимке: уходим с вкладки и возвращаемся — у верха тот же блок, снимки совпадают.
    private func checkReturnSnapshot(_ page: RichProbePage, label: String) throws -> Bool {
        let other = try RichProbePage.editor(for: page.pageId, in: page.store)
        let ownId = page.textView.document.pageDocument.page.id
        let anchor = page.scrollAnchor()
        page.pump(300)
        guard let before = page.snapshot() else { return false }
        page.show(other)
        page.pump(300)
        page.show(try RichProbePage.editor(for: ownId, in: page.store))
        page.window.displayIfNeeded()
        page.restore(anchor)
        page.pump(300)
        guard let after = page.snapshot() else { return false }
        let difference = Self.differenceFraction(before, after)
        let shots = [page.save(before, name: "tabs-\(label)-до-ухода", to: self), page.save(after, name: "tabs-\(label)-после-возврата", to: self)]
        let frameView = try XCTUnwrap(page.window.contentView?.superview)
        let ink = RichProbePage.inkFraction(in: after, rect: page.textView.convert(page.textView.visibleRect, to: frameView), frameView: frameView)
        print("""
            Проба вкладок: возврат на вкладку — у верха блок \(anchor.block)+\(Int(anchor.offset)) → \(page.scrollAnchor().block)+\(Int(page.scrollAnchor().offset)), \
            отличие снимков \(String(format: "%.2f", difference * 100)) %, нарисовано \(String(format: "%.0f", ink * 100)) %
            Снимок: \(shots.joined(separator: ", "))
            """)
        XCTAssertGreaterThan(ink, 0.02, "После возврата вкладки страница не нарисована")
        return difference < 0.02
    }

    /// Редакторы колонок и ячеек открытой страницы: столько живых — норма.
    static func flowEditorsOnScreen(_ page: RichProbePage) -> Int {
        func count(_ view: NSView) -> Int { (view is PageTextView && view !== page.textView ? 1 : 0) + view.subviews.map(count).reduce(0, +) }
        return count(page.textView)
    }

    /// Доля различающихся пикселей двух снимков одного размера.
    static func differenceFraction(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 1 }
        var different = 0, total = 0
        for y in stride(from: 0, to: a.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: a.pixelsWide, by: 3) {
                total += 1
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent) > 0.1 {
                    different += 1
                }
            }
        }
        return Double(different) / Double(max(total, 1))
    }
}
