import AppKit
import Testing
import VisualStyle
@testable import DatabaseGrid
@testable import NotesCore

/// Плашка варианта (T028): 10 цветов Notion в обеих темах; тёмная — по снимку Notion 7.39.
@MainActor
@Suite("Плашка варианта")
struct OptionChipTests {
    func rgb(_ color: NSColor, dark: Bool) -> [Int] {
        var result: [Int] = []
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            result = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        return result
    }

    @Test("У каждого из 10 цветов — свой фон в обеих темах; тёмная «Orange» — как фон плашки на снимке Notion")
    func colors() {
        let dark = OptionColor.allCases.map { rgb(Palette.optionChipBackground($0.rawValue), dark: true) }
        let light = OptionColor.allCases.map { rgb(Palette.optionChipBackground($0.rawValue), dark: false) }
        #expect(Set(dark.map { $0.description }).count == 10 && Set(light.map { $0.description }).count == 10)
        #expect(rgb(Palette.optionChipBackground("orange"), dark: true) == [142, 88, 53])
        #expect(rgb(Palette.optionChipBackground("неизвестный"), dark: true) == rgb(Palette.optionChipBackground("default"), dark: true))
    }

    @Test("Размер плашки — по названию, высота 20; поля по 6")
    func size() {
        let short = OptionChip.size(for: "A"), long = OptionChip.size(for: "Очень длинное название")
        #expect(short.height == 20 && long.width > short.width && short.width > 12)
        let chip = OptionChip(title: "Срочно", color: .orange)
        #expect(chip.intrinsicContentSize == OptionChip.size(for: "Срочно"))
    }
}
