import Testing
@testable import PageEditor

/// Путь в верхней полосе (contracts/visual-style.md, «Страница»): длинный путь прячет середину целыми страницами,
/// название обрезается по границе слова, слова многоточием не рубятся.
@Suite("Путь страницы в верхней полосе")
struct BreadcrumbTextTests {
    /// Ширина — по числу символов: так ожидаемые строки видны прямо в тесте.
    static func measure(_ text: String) -> Double { Double(text.count) }
    static let deepPath = ["Проекты", "Работа над приложением заметок", "Отчёт о скорости",
                           "Черновик таблиц с замерами скорости набора текста"]

    func fit(_ titles: [String], _ width: Double) -> String {
        BreadcrumbText.fitting(titles, width: width, measure: Self.measure(_:))
    }

    @Test("Путь помещается — показан целиком")
    func fullPathWhenItFits() {
        #expect(fit(["Буфер", "📘 MyNotion — образец"], 100) == "Буфер / 📘 MyNotion — образец")
    }

    @Test("Не помещается — середина прячется в «…» целыми страницами, начиная от корня")
    func middleCollapsesWholePages() {
        let full = Self.deepPath.joined(separator: " / ")
        #expect(fit(Self.deepPath, Double(full.count) - 1)
            == "Проекты / … / Отчёт о скорости / Черновик таблиц с замерами скорости набора текста")
        #expect(fit(Self.deepPath, 70) == "Проекты / … / Черновик таблиц с замерами скорости набора текста")
    }

    @Test("Не помещается и так — название страницы обрезается по границе слова")
    func titleTruncatesAtWordBoundary() {
        #expect(fit(Self.deepPath, 40) == "Проекты / … / Черновик таблиц с…")
        #expect(fit(["📘 MyNotion — образец"], 14) == "📘 MyNotion…", "Тире на конце перед «…» не остаётся")
    }

    @Test("При любой ширине путь помещается и слова не рубятся")
    func neverOverflowsNorCutsWords() {
        let words = Set(Self.deepPath.flatMap { $0.split(separator: " ").map(String.init) })
        let full = Self.deepPath.joined(separator: " / ")
        for width in 20...(full.count + 5) {
            let text = fit(Self.deepPath, Double(width))
            #expect(text.count <= width, "ширина \(width): «\(text)»")
            for token in text.split(separator: " ").map({ $0.replacingOccurrences(of: "…", with: "") }) where !token.isEmpty && token != "/" {
                #expect(words.contains(token), "ширина \(width): слово «\(token)» разрублено в «\(text)»")
            }
        }
    }
}
