import AppKit
import Testing
@testable import MathRendering

/// Формулы LaTeX (research R6): SwiftMath с одним шрифтом Latin Modern Math, картинки в кэше по записи, размеру и теме.
@MainActor
@Suite("Отрисовка формул")
struct FormulaRenderingTests {
    nonisolated static let formulas = [
        "\\frac{a+b}{c}", "\\sqrt{x^2+1}", "x_{i}^{2} + y_j", "\\begin{pmatrix} 1 & 0 \\\\ 0 & 1 \\end{pmatrix}",
        "\\begin{aligned} a &= b + c \\\\ d &= e \\end{aligned}", "f(x) = \\begin{cases} 1 & x > 0 \\\\ 0 & x \\le 0 \\end{cases}",
        "\\alpha + \\beta = \\gamma", "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}", "E = mc^2",
        // Формулы живой выгрузки Notion (T116).
        "a^2+b^2",
    ]

    @Test("Дроби, корни, индексы, матрицы, aligned, cases — картинка без ошибки", arguments: formulas)
    func renders(_ latex: String) throws {
        let cache = FormulaImageCache()
        guard case .rendered(let formula) = cache.render(latex, fontSize: 17, theme: .light) else {
            Issue.record("Не отрисовалась: \(latex)")
            return
        }
        #expect(formula.image.size.width > 10)
        #expect(formula.image.size.height > 10)
        #expect(formula.ascent > 0)
        // Нарисовано хоть что-то тёмное на прозрачном.
        let tiff = try #require(formula.image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        var ink = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { ink += 1 } }
        #expect(ink > 20)
    }

    @Test("Ошибка разбора — «Неверная формула», запись не меняется")
    func invalidFormula() {
        let cache = FormulaImageCache()
        let latex = "\\frac{a}{"
        guard case .invalid = cache.render(latex, fontSize: 17, theme: .light) else {
            Issue.record("Ошибка не распознана")
            return
        }
        #expect(FormulaImageCache.invalidFormulaText == "Неверная формула")
        #expect(latex == "\\frac{a}{")
        if case .invalid = cache.render("\\unknowncommand{x}", fontSize: 17, theme: .light) {} else { Issue.record("Незнакомая команда не ошибка") }
    }

    @Test("Пустая запись — пусто, а не ошибка")
    func emptyFormula() {
        let cache = FormulaImageCache()
        guard case .empty = cache.render("  ", fontSize: 17, theme: .light) else {
            Issue.record("Пустая — не пусто")
            return
        }
        #expect(FormulaImageCache.emptyFormulaText == "Новая формула")
    }

    @Test("Кэш по записи, размеру и теме: повтор не рисует заново")
    func cacheKey() {
        let cache = FormulaImageCache()
        _ = cache.render("x^2", fontSize: 17, theme: .light)
        _ = cache.render("x^2", fontSize: 17, theme: .light)
        #expect(cache.renderCount == 1)
        _ = cache.render("x^2", fontSize: 17, theme: .dark)
        _ = cache.render("x^2", fontSize: 14, theme: .light)
        _ = cache.render("x^3", fontSize: 17, theme: .light)
        #expect(cache.renderCount == 4)
        _ = cache.render("x^2", fontSize: 17, theme: .dark)
        #expect(cache.renderCount == 4)
    }

    @Test("Тёмная тема — светлые чернила")
    func darkThemeInk() throws {
        let cache = FormulaImageCache()
        guard case .rendered(let light) = cache.render("x", fontSize: 30, theme: .light),
              case .rendered(let dark) = cache.render("x", fontSize: 30, theme: .dark) else {
            Issue.record("Нет картинок")
            return
        }
        func brightestInk(_ image: NSImage) throws -> CGFloat {
            let tiff = try #require(image.tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: tiff))
            var best: CGFloat = 0
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else { continue }
                    best = max(best, color.brightnessComponent)
                }
            }
            return best
        }
        #expect(try brightestInk(light.image) < 0.4)
        #expect(try brightestInk(dark.image) > 0.7)
    }

    @Test("Шрифт загружается при первой формуле, а не при создании кэша")
    func fontLoadsLazily() {
        let cache = FormulaImageCache()
        #expect(!cache.isFontLoaded)
        _ = cache.render("y", fontSize: 17, theme: .light)
        #expect(cache.isFontLoaded)
    }

    @Test("Формула в строке меньше формулы-блока")
    func inlineMode() {
        let cache = FormulaImageCache()
        guard case .rendered(let block) = cache.render("\\sum_{i=1}^{n} i", fontSize: 17, theme: .light, mode: .display),
              case .rendered(let inline) = cache.render("\\sum_{i=1}^{n} i", fontSize: 17, theme: .light, mode: .inline) else {
            Issue.record("Нет картинок")
            return
        }
        #expect(inline.image.size.height < block.image.size.height)
    }
}
