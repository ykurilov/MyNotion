import Foundation
import Testing
@testable import PageEditor

/// Путь над страницей как в Notion: каждый предок — отдельная нажимаемая часть, длинный путь —
/// «первый, …, последние два», текущая страница — последняя и не нажимается.
@Suite("Части пути над страницей")
struct BreadcrumbPathTests {
    static func measure(_ text: String) -> Double { Double(text.count) }
    static let ids = (0..<6).map { _ in UUID() }
    static let titles = ["Корень", "Проекты", "Работа", "Отчёты", "Черновик"]

    static func ancestors(_ count: Int) -> [BreadcrumbAncestor] {
        (0..<count).map { BreadcrumbAncestor(pageId: ids[$0], title: titles[$0]) }
    }

    func parts(ancestors count: Int, current: String = "Страница", width: Double) -> [BreadcrumbPath.Part] {
        BreadcrumbPath.parts(ancestors: Self.ancestors(count), current: current, width: width, measure: Self.measure(_:))
    }

    @Test("Путь помещается — каждый предок отдельной нажимаемой частью, текущая последняя")
    func everyAncestorIsOwnPart() {
        let result = parts(ancestors: 2, width: 200)
        #expect(result == [.page(Self.ancestors(2)[0]), .page(Self.ancestors(2)[1]), .current("Страница")])
    }

    @Test("Корневая страница — только текущая часть")
    func rootPageHasOnlyCurrent() {
        #expect(parts(ancestors: 0, width: 200) == [.current("Страница")])
    }

    @Test("Не помещается — первый, «…», последние два; в «…» спрятаны средние предки по порядку")
    func longPathKeepsFirstAndLastTwo() {
        let all = Self.ancestors(4)
        let result = parts(ancestors: 4, width: 40)
        #expect(result == [.page(all[0]), .hidden([all[1], all[2]]), .page(all[3]), .current("Страница")])
    }

    @Test("Текущая страница — всегда последняя часть, её нельзя нажать")
    func currentIsLastAndNotClickable() {
        for width in stride(from: 10.0, through: 120.0, by: 5) {
            let result = parts(ancestors: 4, width: width)
            guard case .current = result.last else { Issue.record("ширина \(width): последняя часть не текущая: \(result)"); continue }
            #expect(result.dropLast().allSatisfy { if case .current = $0 { false } else { true } })
        }
    }

    @Test("Совсем узко — остаются первый, «…» и текущая страница, название режется по слову")
    func narrowTruncatesCurrentTitle() {
        let all = Self.ancestors(4)
        let result = parts(ancestors: 4, current: "Длинное название страницы", width: 26)
        #expect(result.first == .page(all[0]))
        guard case .current(let title) = result.last else { Issue.record("нет текущей части: \(result)"); return }
        #expect(title.hasSuffix("…") && title.count < "Длинное название страницы".count)
    }

    @Test("Два и три предка без нужды ничего не прячут")
    func shortPathsNeverCollapseWhenTheyFit() {
        for count in 1...3 {
            let result = parts(ancestors: count, width: 500)
            #expect(result.count == count + 1, "предков \(count): \(result)")
            #expect(!result.contains { if case .hidden = $0 { true } else { false } })
        }
    }
}
