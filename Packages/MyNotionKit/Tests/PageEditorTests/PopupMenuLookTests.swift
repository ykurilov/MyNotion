import AppKit
import Testing
@testable import PageEditor
import VisualStyle

/// Вид всплывающих меню по снимкам: меню отделено от страницы в обеих темах; меню «/» — плотный список как в Notion
/// 7.38.1 (ui-review 15.10.2026, № 1): строка 33, маленький значок без рамки, название, справа серым быстрые символы,
/// заголовок раздела «Основные блоки», внизу «Закрыть меню» с «esc»; меню блока — те же строки
/// (contracts/visual-style.md, «Всплывающие меню»).
@MainActor
@Suite("Вид меню «/» и меню блока")
struct PopupMenuLookTests {
    nonisolated static let themes: [NSAppearance.Name] = [.aqua, .darkAqua]

    static func items(_ style: PopupMenuStyle) -> [PopupMenuItem] {
        PopupMenuItem.blockKinds + (style == .block ? [.delete] : [])
    }

    static func menu(_ style: PopupMenuStyle) -> PopupMenuView {
        let view = PopupMenuView(style: style)
        view.setItems(items(style))
        let margin = PopupMenuWindow.shadowMargin
        let size = view.fittingMenuSize
        view.frame = NSRect(x: 0, y: 0, width: size.width + 2 * margin, height: size.height + 2 * margin)
        view.layoutSubtreeIfNeeded()
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

    // MARK: Строки

    @Test("Меню «/»: заголовок раздела, строки по 33, внизу «Закрыть меню» — места как у Notion")
    func slashMenuLayout() throws {
        let view = Self.menu(.slash)
        let top = PopupMenuWindow.shadowMargin
        let rows = view.subviews.compactMap { $0 as? PopupMenuRowView }
        try #require(rows.count == 7)
        #expect(view.sectionTitle == "Основные блоки")
        // У Notion: середина заголовка раздела ≈ 18,6 ниже верха меню, середина первой строки ≈ 49,8.
        #expect(abs(rows[0].frame.midY - top - 49.8) <= 1.2, "Первая строка с \(rows[0].frame.minY - top) от верха меню")
        for (index, row) in rows.enumerated() {
            #expect(row.frame.height == 33, "\(row.item.title): строка \(row.frame.height)")
            if index > 0 { #expect(row.frame.minY - rows[index - 1].frame.minY == 33) }
        }
        let footer = try #require(view.footer, "Нет строки «Закрыть меню»")
        #expect(footer.title == "Закрыть меню" && footer.key == "esc")
        #expect(footer.frame.minY == rows[6].frame.maxY && footer.frame.height == 33)
        let bottom = top + view.fittingMenuSize.height
        #expect(abs(bottom - footer.frame.midY - 18.6) <= 1.2, "Под серединой «Закрыть меню» \(bottom - footer.frame.midY), у Notion 18,6")
    }

    @Test("Заголовок раздела — мелкий серый, с края текста строк", arguments: Self.themes)
    func sectionTitleIsSmallGray(theme: NSAppearance.Name) throws {
        let view = Self.menu(.slash)
        let pixels = try ViewPixels(view, appearance: theme)
        let top = PopupMenuWindow.shadowMargin
        let rows = view.subviews.compactMap { $0 as? PopupMenuRowView }
        // Без рамки и скруглённых углов меню.
        let corner = Metrics.PopupMenu.cornerRadius
        let band = NSRect(x: top + corner, y: top + 2, width: Metrics.PopupMenu.slashMenuWidth - 2 * corner, height: rows[0].frame.minY - top - 2)
        let background = Palette.popupMenuBackground.resolved(in: theme)
        let ink = try #require(pixels.inkBounds(in: band, over: background), "Заголовка раздела не видно")
        #expect(abs(ink.minX - top - 12) <= 1.5, "Заголовок с \(ink.minX - top) от края меню, у Notion 12")
        #expect(abs(ink.midY - top - 18.6) <= 1.5, "Середина заголовка \(ink.midY - top) от верха меню, у Notion 18,6")
        #expect(ink.height <= 12, "Заголовок \(ink.height) — крупно для 12 pt")
        let color = try #require(pixels.strongestInkColor(in: ink, over: background))
        #expect(colorDistance(color, Palette.textSecondary.resolved(in: theme)) <= 0.12, "Заголовок \(color) — не textSecondary")
    }

    @Test("Меню блока — те же строки 33, без заголовка раздела и «Закрыть меню»")
    func blockMenuLayout() throws {
        let view = Self.menu(.block)
        let rows = view.subviews.compactMap { $0 as? PopupMenuRowView }
        try #require(rows.count == 8)
        #expect(view.sectionTitle == nil && view.footer == nil)
        #expect(rows.allSatisfy { $0.frame.height == 33 })
        #expect(rows[0].frame.minY == PopupMenuWindow.shadowMargin + Metrics.PopupMenu.verticalPadding)
    }

    @Test("Быстрые символы типов — как в Notion")
    func shortcuts() {
        #expect(PopupMenuItem.blockKinds.map(\.shortcut) == [nil, "#", "##", "###", "-", "1.", "[]"])
    }

    /// Строка без выделения отдельно, в обеих темах.
    static func row(_ item: PopupMenuItem, _ style: PopupMenuStyle, theme: NSAppearance.Name) throws -> (view: PopupMenuRowView, pixels: ViewPixels) {
        let row = PopupMenuRowView(item: item, style: style)
        row.frame = NSRect(x: 0, y: 0, width: style.width - 2 * Metrics.PopupMenu.rowInset, height: Metrics.PopupMenu.rowHeight)
        return (row, try ViewPixels(row, appearance: theme))
    }

    @Test("Справа в строке «/» — быстрые символы серым, как у Notion в ≈ 10 от края строки; у «Текст» и в меню блока их нет", arguments: Self.themes)
    func shortcutsDrawnGrayOnTheRight(theme: NSAppearance.Name) throws {
        for item in PopupMenuItem.blockKinds {
            let (view, pixels) = try Self.row(item, .slash, theme: theme)
            let right = NSRect(x: view.bounds.width - 40, y: 0, width: 40, height: view.bounds.height)
            guard item.shortcut != nil else {
                #expect(pixels.inkBounds(in: right) == nil, "\(item.title): справа что-то нарисовано")
                continue
            }
            let ink = try #require(pixels.inkBounds(in: right), "\(item.title): быстрых символов не видно")
            #expect(abs(view.bounds.width - ink.maxX - 10) <= 1.5,
                    "\(item.title): символы кончаются в \(view.bounds.width - ink.maxX) от края строки")
            let color = try #require(pixels.averageInkColor(in: ink))
            #expect(colorDistance(color, Palette.textSecondary.resolved(in: theme)) <= 0.15, "\(item.title): символы \(color) — не textSecondary")
        }
        let (view, pixels) = try Self.row(PopupMenuItem.blockKinds[1], .block, theme: theme)
        #expect(pixels.inkBounds(in: NSRect(x: view.bounds.width - 40, y: 0, width: 40, height: view.bounds.height)) == nil,
                "В меню блока быстрых символов нет")
    }

    @Test("Без пояснений: одна строка названия 14 pt по середине строки, с 40 от края меню", arguments: [PopupMenuStyle.slash, .block])
    func singleLineTitle(style: PopupMenuStyle) throws {
        for item in Self.items(style) {
            let (view, pixels) = try Self.row(item, style, theme: .aqua)
            let textX = Metrics.PopupMenu.rowHorizontalPadding + Metrics.PopupMenu.iconSize + 1
            let ink = try #require(pixels.inkBounds(in: NSRect(x: textX, y: 0, width: view.bounds.width - textX - 44, height: view.bounds.height)))
            #expect(ink.height <= 15, "\(style), \(item.title): текст в \(ink.height) — больше одной строки")
            #expect(abs(ink.midY - view.bounds.midY) <= 2, "\(style), \(item.title): текст \(ink) не по середине строки")
            #expect(abs(ink.minX + Metrics.PopupMenu.rowInset - 40) <= 1.5, "\(style), \(item.title): название с \(ink.minX + Metrics.PopupMenu.rowInset) от края меню, у Notion 40")
        }
    }

    // MARK: Значки

    /// Рамки нарисованных значков строк, без выделения строки.
    static func iconInk(_ style: PopupMenuStyle, theme: NSAppearance.Name) throws -> [(item: PopupMenuItem, ink: NSRect, box: NSRect, pixels: ViewPixels)] {
        try items(style).map { item in
            let (_, pixels) = try row(item, style, theme: theme)
            let size = Metrics.PopupMenu.iconSize
            let box = NSRect(x: Metrics.PopupMenu.rowHorizontalPadding, y: (Metrics.PopupMenu.rowHeight - size) / 2, width: size, height: size)
            // Сглаживание краёв добавляет до полточки с каждой стороны.
            let ink = try #require(pixels.inkBounds(in: box.insetBy(dx: -2, dy: -2)), "\(item.title): значок не нарисован")
            return (item, ink, box, pixels)
        }
    }

    @Test("Значки — маленькие, без рамки-плитки, в колонке 20 по центру; надписи «T», «H₁»… одним шрифтом",
          arguments: [PopupMenuStyle.slash, .block])
    func iconsShareColumn(style: PopupMenuStyle) throws {
        let icons = try Self.iconInk(style, theme: .aqua)
        let side = Metrics.PopupMenu.iconInkSize
        let report = icons.map { "\($0.item.title) \($0.ink.width)×\($0.ink.height)" }
        for icon in icons {
            #expect(icon.ink.width <= side + 1 && icon.ink.height <= side + 1,
                    "\(style), \(icon.item.title): значок \(icon.ink.size) больше квадрата \(side); все: \(report)")
            #expect(icon.ink.width >= 8 || icon.ink.height >= 8, "\(style), \(icon.item.title): значок \(icon.ink.size) слишком мал")
            #expect(abs(icon.ink.midX - icon.box.midX) <= 1 && abs(icon.ink.midY - icon.box.midY) <= 2.5,
                    "\(style), \(icon.item.title): значок \(icon.ink) не по центру места \(icon.box)")
        }
        let labels = icons.filter { if case .label = $0.item.icon { true } else { false } }
        let tops = labels.map(\.ink.minY)
        #expect((tops.max() ?? 0) - (tops.min() ?? 0) <= 1, "\(style): надписи «T», «H₁»… одним шрифтом от одной линии: \(report)")
    }

    @Test("Значок «Удалить» того же красного, что и надпись", arguments: Self.themes)
    func deleteIconIsRed(theme: NSAppearance.Name) throws {
        let delete = try #require(try Self.iconInk(.block, theme: theme).first { $0.item.action == .delete })
        let color = try #require(delete.pixels.averageInkColor(in: delete.ink))
        let red = Palette.destructiveText.resolved(in: theme)
        #expect(colorDistance(color, red) <= 0.12, "\(theme.rawValue): значок \(color), надпись \(red)")
    }
}
