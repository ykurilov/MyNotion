import AppKit
import Testing
@testable import DatabaseViewBar
import VisualStyle

/// Значки строки вида (T085): одна картинка на символ, цвет и оформление — отрисовка не подбирает символ заново.
@MainActor
@Suite("Значки строки вида")
struct ViewBarSymbolsTests {
    @Test("Повторная отрисовка берёт ту же картинку; другой цвет или тёмное оформление — другую")
    func reusesImage() throws {
        let light = try #require(NSAppearance(named: .aqua)), dark = try #require(NSAppearance(named: .darkAqua))
        var first: NSImage?, again: NSImage?, active: NSImage?, night: NSImage?
        light.performAsCurrentDrawingAppearance {
            first = ViewBarSymbols.image("arrow.up.arrow.down", pointSize: 13, weight: .regular, color: Palette.textSecondary)
            again = ViewBarSymbols.image("arrow.up.arrow.down", pointSize: 13, weight: .regular, color: Palette.textSecondary)
            active = ViewBarSymbols.image("arrow.up.arrow.down", pointSize: 13, weight: .regular, color: Palette.activeViewControl)
        }
        dark.performAsCurrentDrawingAppearance {
            night = ViewBarSymbols.image("arrow.up.arrow.down", pointSize: 13, weight: .regular, color: Palette.textSecondary)
        }
        let image = try #require(first)
        #expect(again === image)
        #expect(active !== image)
        #expect(night !== image)
    }
}
