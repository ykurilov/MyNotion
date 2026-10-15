import AppKit
import Testing
@testable import PageEditor
import VisualStyle

/// Вид всплывающих меню по снимкам: меню отделено от страницы в обеих темах, значки строк одного размера
/// (contracts/visual-style.md, «Всплывающие меню»; ui-review 15.10.2026, № 4 и 6).
@MainActor
@Suite("Вид меню «/» и меню блока")
struct PopupMenuLookTests {
    nonisolated static let themes: [NSAppearance.Name] = [.aqua, .darkAqua]

    static func menu(_ style: PopupMenuStyle) -> PopupMenuView {
        let view = PopupMenuView(style: style)
        view.setItems(PopupMenuItem.blockKinds + (style == .block ? [.delete] : []))
        let margin = PopupMenuWindow.shadowMargin
        let size = view.fittingMenuSize
        view.frame = NSRect(x: 0, y: 0, width: size.width + 2 * margin, height: size.height + 2 * margin)
        return view
    }

    @Test("Край меню виден на странице в обеих темах, в тёмной фон меню светлее страницы", arguments: [PopupMenuStyle.slash, .block])
    func menuStandsOutFromPage(style: PopupMenuStyle) throws {
        for theme in Self.themes {
            let view = Self.menu(style)
            let pixels = try ViewPixels(view, appearance: theme)
            let page = Palette.pageBackground.resolved(in: theme)
            let margin = PopupMenuWindow.shadowMargin
            let menu = NSRect(x: margin, y: margin, width: style.width, height: view.fittingMenuSize.height)

            // Рамка меню: точка сразу за краем, слева и справа.
            for edge in [NSPoint(x: menu.minX - 0.5, y: menu.midY), NSPoint(x: menu.maxX + 0.5, y: menu.midY)] {
                let distance = colorDistance(pixels.color(at: edge, over: page), page)
                #expect(distance >= 0.05, "\(theme.rawValue), \(style): край меню отличается от страницы на \(distance)")
            }
            if theme == .darkAqua {
                // Поле меню справа от строк — фон меню.
                let inside = pixels.color(at: NSPoint(x: menu.maxX - 2, y: menu.midY), over: page)
                #expect(colorDistance(inside, page) >= 0.03, "Тёмная тема, \(style): фон меню \(inside) сливается со страницей \(page)")
            }
        }
    }

    /// Рамки нарисованных значков строк, без выделения строки.
    static func iconInk(_ style: PopupMenuStyle, theme: NSAppearance.Name) throws -> [(item: PopupMenuItem, ink: NSRect, box: NSRect, pixels: ViewPixels)] {
        let items = PopupMenuItem.blockKinds + (style == .block ? [.delete] : [])
        return try items.map { item in
            let row = PopupMenuRowView(item: item, style: style)
            row.frame = NSRect(x: 0, y: 0, width: style.width - 2 * Metrics.PopupMenu.rowInset, height: style.rowHeight)
            let pixels = try ViewPixels(row, appearance: theme)
            let size = min(style.iconSize, style.rowHeight)
            let box = NSRect(x: Metrics.PopupMenu.rowHorizontalPadding, y: (style.rowHeight - size) / 2, width: size, height: size)
            // В меню «/» значок в рамке: мерить внутри неё.
            let area = style == .slash ? box.insetBy(dx: 2, dy: 2) : box
            let ink = try #require(pixels.inkBounds(in: area), "\(item.title): значок не нарисован")
            return (item, ink, box, pixels)
        }
    }

    @Test("Значки строк одного размера и по центру своего места", arguments: [PopupMenuStyle.slash, .block])
    func iconsShareSize(style: PopupMenuStyle) throws {
        let icons = try Self.iconInk(style, theme: .aqua)
        let heights = icons.map(\.ink.height)
        let smallest = try #require(heights.min()), largest = try #require(heights.max())
        #expect(largest / smallest <= 1.35,
                "\(style): высота значков от \(smallest) до \(largest): \(icons.map { "\($0.item.title) \($0.ink.height)" })")
        for icon in icons {
            #expect(icon.ink.width <= icon.box.width && icon.ink.height <= icon.box.height, "\(icon.item.title) не помещается в своё место")
            #expect(abs(icon.ink.midX - icon.box.midX) <= 1.5 && abs(icon.ink.midY - icon.box.midY) <= 1.5,
                    "\(style), \(icon.item.title): значок \(icon.ink) не по центру места \(icon.box)")
        }
    }

    @Test("Значок «Удалить» того же красного, что и надпись", arguments: Self.themes)
    func deleteIconIsRed(theme: NSAppearance.Name) throws {
        let delete = try #require(try Self.iconInk(.block, theme: theme).first { $0.item.action == .delete })
        let color = try #require(delete.pixels.averageInkColor(in: delete.ink))
        let red = Palette.destructiveText.resolved(in: theme)
        #expect(colorDistance(color, red) <= 0.12, "\(theme.rawValue): значок \(color), надпись \(red)")
    }
}
