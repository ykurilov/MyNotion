import AppKit
import Testing
@testable import VisualStyle

/// Меню действий — меню «•••» страницы и меню строки панели — как у Notion 7.39 (замер 21.10.2026, проверка T101 № 1, 2, 9, 10):
/// значок 20 в 8 от края пункта, название в 36, подсказка клавиш и «›» целиком в 8 от правого края, поле поиска в 12 от краёв
/// с синей рамкой в фокусе; меню строки — от середины «⋯» вправо и вниз.
@MainActor
@Suite("Геометрия меню действий")
struct ActionMenuGeometryTests {
    static func menu(width: CGFloat = Metrics.PageMenu.width) -> ActionMenuView {
        let menu = ActionMenuView(entries: [
            .search(placeholder: "Найти действие…", identifier: nil),
            .action(ActionMenuAction(title: "Дублировать", icon: "square.on.square", hint: "⌘D") { _ in }),
            .action(ActionMenuAction(title: "Переместить в", icon: "arrow.turn.up.right", hint: "⌘⇧P") { _ in }),
            .separator,
            .action(ActionMenuAction(title: "Вид страницы", icon: "textformat", opensSubmenu: true) { _ in }),
            .separator,
            .action(ActionMenuAction(title: "Удалить в корзину", icon: "trash", hint: "⌘⌫") { _ in }),
            .footer("Изменено: сегодня в 14:59, 87 слов", identifier: nil),
        ], width: width)
        menu.frame.size = menu.fittingSize
        menu.layoutSubtreeIfNeeded()
        return menu
    }

    /// Рамка нарисованного в `area` вида (непрозрачность выше 0,3), в точках вида.
    static func ink(_ view: NSView, in area: NSRect, appearance: NSAppearance.Name = .aqua) throws -> NSRect? {
        view.appearance = NSAppearance(named: appearance)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for row in 0..<bitmap.pixelsHigh {
            for column in 0..<bitmap.pixelsWide {
                let point = NSPoint(x: (CGFloat(column) + 0.5) / scale, y: (CGFloat(row) + 0.5) / scale)
                let y = view.isFlipped ? point.y : view.bounds.height - point.y
                guard area.contains(NSPoint(x: point.x, y: y)), (bitmap.colorAt(x: column, y: row)?.alphaComponent ?? 0) > 0.3 else { continue }
                minX = min(minX, column); maxX = max(maxX, column); minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard minX <= maxX else { return nil }
        return NSRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale,
                      height: CGFloat(maxY - minY + 1) / scale)
    }

    @Test("Пункты: шаг 29 в 4 от краёв карточки, значок 20 в 8 от края пункта, название в 36")
    func rowsLikeNotion() throws {
        let menu = Self.menu()
        let rows = menu.rowViews
        #expect(rows.allSatisfy { $0.frame.minX == 4 && $0.frame.width == Metrics.PageMenu.width - 8 })
        #expect(rows[1].frame.minY - rows[0].frame.minY == 29)
        for row in rows {
            #expect(row.iconRect == NSRect(x: 8, y: 4, width: 20, height: 20), "\(row.action.title): \(row.iconRect)")
            #expect(row.titleX == 36)
            let icon = try #require(try Self.ink(row, in: row.iconRect), "\(row.action.title): значка нет")
            #expect(max(icon.width, icon.height) >= 15, "\(row.action.title): значок \(icon) мельче Notion (16)")
            #expect(abs(icon.midX - row.iconRect.midX) <= 1, "\(row.action.title): значок не по центру своего места")
        }
    }

    @Test("Подсказка клавиш целиком, правым краем в 8 от края пункта (12 от края карточки)", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func hintsNotClipped(_ theme: NSAppearance.Name) throws {
        let menu = Self.menu()
        for row in menu.rowViews where row.action.hint != nil {
            let hintRect = try #require(row.hintRect)
            let text = NSAttributedString(string: row.action.hint!, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            #expect(hintRect.width >= text.size().width, "\(row.action.hint!): место \(hintRect.width) уже текста \(text.size().width)")
            let ink = try #require(try Self.ink(row, in: NSRect(x: row.bounds.midX, y: 0, width: row.bounds.width / 2, height: row.bounds.height),
                                                appearance: theme))
            #expect(row.bounds.maxX - ink.maxX >= 7.5 && row.bounds.maxX - ink.maxX <= 9.5,
                    "\(row.action.hint!): правый край \(ink.maxX) из \(row.bounds.maxX)")
            #expect(ink.width >= text.size().width - 2, "\(row.action.hint!): обрезана, видно \(ink.width) из \(text.size().width)")
        }
    }

    @Test("«›» подменю — рисунок в квадрате 16 в 8 от правого края пункта, не мельче 8 по высоте")
    func chevronLikeNotion() throws {
        let menu = Self.menu()
        let row = try #require(menu.rowViews.first { $0.action.opensSubmenu })
        #expect(row.chevronRect == NSRect(x: row.bounds.maxX - 24, y: 6, width: 16, height: 16))
        let ink = try #require(try Self.ink(row, in: NSRect(x: row.bounds.maxX - 30, y: 0, width: 30, height: row.bounds.height)))
        #expect(ink.height >= 8, "стрелка \(ink.height) — мельче, чем у Notion")
        #expect(row.bounds.maxX - ink.maxX >= 8 && ink.minX >= row.chevronRect.minX, "стрелка \(ink) вне своего квадрата")
    }

    @Test("Поле поиска 28 в 12 от краёв карточки; до первого пункта 12")
    func searchFieldPlace() throws {
        let menu = Self.menu()
        let search = try #require(menu.searchBox)
        #expect(search.frame == NSRect(x: 12, y: 12, width: Metrics.PageMenu.width - 24, height: 28))
        #expect(menu.rowViews[0].frame.minY - search.frame.maxY == 12)
    }

    @Test("Поле поиска в фокусе — синяя рамка, без фокуса — серая", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func searchFocusRing(_ theme: NSAppearance.Name) throws {
        let menu = Self.menu()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: menu.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = menu
        let search = try #require(menu.searchBox)
        func edge() throws -> NSColor {
            search.appearance = NSAppearance(named: theme)
            let bitmap = try #require(search.bitmapImageRepForCachingDisplay(in: search.bounds))
            search.cacheDisplay(in: search.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / search.bounds.width
            // Рамка — обводка по краю поля, отступившему на 1 точку: середина линии на y = 1 при любой толщине.
            return try #require(bitmap.colorAt(x: Int(search.bounds.midX * scale), y: Int(1 * scale))?.usingColorSpace(.sRGB))
        }
        let idle = try edge()
        #expect(idle.blueComponent - idle.redComponent < 0.1, "без фокуса рамка уже синяя: \(idle)")
        window.makeFirstResponder(search.field)
        #expect(search.isFocused)
        let focused = try edge()
        #expect(focused.blueComponent - focused.redComponent > 0.4, "рамка в фокусе не синяя: \(focused)")
    }

    // MARK: Место меню строки

    let window = NSRect(x: 0, y: 0, width: 1440, height: 900)

    @Test("Меню строки — левым верхним углом в середине «⋯», вправо и вниз (как у Notion)")
    func rowMenuFromButtonCenter() {
        let center = NSPoint(x: 248, y: 600)
        let card = PopupCard.cardFrame(size: NSSize(width: 265, height: 300), from: center, in: window)
        #expect(card.minX == center.x && card.maxY == center.y)
    }

    @Test("Внизу окна меню строки встаёт вверх, низом по середине «⋯»; у правого края — влево")
    func rowMenuFlips() {
        let low = PopupCard.cardFrame(size: NSSize(width: 265, height: 300), from: NSPoint(x: 248, y: 120), in: window)
        #expect(low.minY == 120 && low.minX == 248)
        let right = PopupCard.cardFrame(size: NSSize(width: 265, height: 300), from: NSPoint(x: 1300, y: 600), in: window)
        #expect(right.maxX == 1300)
        let tiny = NSRect(x: 0, y: 0, width: 400, height: 250)
        let clamped = PopupCard.cardFrame(size: NSSize(width: 265, height: 300), from: NSPoint(x: 200, y: 100), in: tiny)
        #expect(clamped.minX >= 8 && clamped.maxX <= tiny.maxX - 8)
    }
}
