import AppKit
import Testing
@testable import EmojiPicker
import VisualStyle

/// Окно выбора иконки-эмодзи, как у Notion (FR-034; contracts/editor-interactions.md, «Иконка страницы»):
/// поиск, разделы, сетка, «Случайная», «Убрать», Esc закрывает; выбранное попадает в «Недавние».
@MainActor
@Suite("Окно выбора эмодзи")
final class EmojiPickerTests {
    let recents = RecentEmojis(defaults: UserDefaults(suiteName: "EmojiPickerTests-\(UUID())")!)
    let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
    let anchor = NSRect(x: 400, y: 700, width: 78, height: 78)
    lazy var picker = EmojiPickerController(recents: recents)
    var chosen: [String?] = []

    private func open() throws -> EmojiPickerView {
        picker.show(below: anchor, in: parent) { [unowned self] in chosen.append($0) }
        return try #require(picker.view)
    }

    // MARK: Открыть и закрыть

    @Test("Открывается под иконкой по её середине; окно страницы невидимо — на экран не выходит")
    func opensBelowAnchor() throws {
        _ = try open()
        #expect(picker.isShown)
        let card = try #require(picker.cardFrame)
        #expect(card.size == NSSize(width: Metrics.EmojiPicker.width, height: Metrics.EmojiPicker.height))
        #expect(card.midX == anchor.midX)
        #expect(card.maxY == anchor.minY - Metrics.EmojiPicker.anchorSpacing)
        #expect(!NSApp.windows.contains { $0.isVisible && $0.accessibilityIdentifier() == "emoji-picker" })
    }

    @Test("У края окна прижимается к нему")
    func clampedToParent() {
        let card = EmojiPickerPlacement.card(size: NSSize(width: 408, height: 390), below: NSRect(x: 110, y: 700, width: 20, height: 20),
                                             within: parent.frame, screen: nil)
        #expect(card.minX == parent.frame.minX)
    }

    @Test("Esc закрывает, ничего не выбрав")
    func escapeCloses() throws {
        let view = try open()
        #expect(view.handleCommand(#selector(NSResponder.cancelOperation(_:))))
        #expect(!picker.isShown)
        #expect(chosen.isEmpty)
    }

    // MARK: Разделы

    @Test("Без недавних — восемь разделов по порядку, значок «Недавних» неактивен; с ними — «Недавние» первыми")
    func sections() throws {
        var view = try open()
        #expect(view.shownSections == [.people, .nature, .food, .activities, .travel, .objects, .symbols, .flags])
        #expect(view.sectionBar.sections == EmojiSection.allCases)
        #expect(!view.sectionBar.isEnabled(.recent))
        #expect(view.isSectionBarShown)
        picker.close()

        recents.add("🌿")
        recents.add("📘")
        view = try open()
        #expect(view.shownSections.first == .recent)
        #expect(view.grid.emojis(in: .recent) == ["📘", "🌿"])
        #expect(view.sectionBar.isEnabled(.recent))
    }

    @Test("Значок раздела внизу прокручивает к разделу и подсвечивается")
    func sectionBarScrolls() throws {
        let view = try open()
        #expect(view.currentSection == .people)
        view.sectionBar.press(.flags)
        #expect(view.currentSection == .flags)
        #expect(view.sectionBar.current == .flags)
    }

    // MARK: Поиск

    @Test("Поиск: результаты без разделов и без строки разделов, первый подсвечен; пусто — «Ничего не найдено»")
    func search() throws {
        let view = try open()
        view.query = "кот"
        #expect(view.grid.allEmojis.contains("🐱"))
        #expect(view.shownSections.isEmpty)
        #expect(!view.isSectionBarShown)
        #expect(view.grid.highlighted == view.grid.allEmojis.first)
        #expect(view.grid.emptyMessage == nil)

        view.query = "щщщщ"
        #expect(view.grid.allEmojis.isEmpty)
        #expect(view.grid.emptyMessage == "Ничего не найдено")

        view.query = ""
        #expect(view.shownSections.first == .people)
        #expect(view.isSectionBarShown)
    }

    // MARK: Выбор

    @Test("Enter ставит подсвеченный, окно закрывается, эмодзи — в «Недавних»")
    func enterChoosesHighlighted() throws {
        let view = try open()
        view.query = "синяя книга"
        #expect(view.handleCommand(#selector(NSResponder.insertNewline(_:))))
        #expect(chosen == ["📘"])
        #expect(!picker.isShown)
        #expect(recents.emojis == ["📘"])
    }

    @Test("Стрелки двигают подсветку по сетке")
    func arrowsMoveHighlight() throws {
        let view = try open()
        view.query = "кот"
        let all = view.grid.allEmojis
        #expect(view.handleCommand(#selector(NSResponder.moveRight(_:))))
        #expect(view.grid.highlighted == all[1])
        #expect(view.handleCommand(#selector(NSResponder.moveLeft(_:))))
        #expect(view.grid.highlighted == all[0])
    }

    @Test("Щелчок по эмодзи в сетке ставит его")
    func clickChooses() throws {
        let view = try open()
        let cell = try #require(view.grid.cellFrame(of: "📘"))
        #expect(view.grid.emoji(at: NSPoint(x: cell.midX, y: cell.midY)) == "📘")
        view.grid.choose("📘")
        #expect(chosen == ["📘"])
        #expect(!picker.isShown)
    }

    @Test("«Случайная» ставит эмодзи из каталога и оставляет окно открытым")
    func randomKeepsOpen() throws {
        let view = try open()
        view.randomButton.press()
        #expect(chosen.count == 1)
        #expect(chosen.first.flatMap { $0 }.flatMap(EmojiCatalog.shared.emoji) != nil)
        #expect(picker.isShown)
    }

    @Test("«Убрать» снимает иконку и закрывает окно")
    func removeClears() throws {
        let view = try open()
        view.removeButton.press()
        #expect(chosen == [nil])
        #expect(!picker.isShown)
    }

    // MARK: Вид

    @Test("Карточка: поле поиска своего цвета с синей рамкой, черта под вкладкой цвета текста", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func looks(_ theme: NSAppearance.Name) throws {
        let view = try open()
        let appearance = try #require(NSAppearance(named: theme))
        let image = try #require(view.renderedCard(appearance: appearance))
        let metrics = Metrics.EmojiPicker.self
        func color(_ x: CGFloat, _ y: CGFloat) -> NSColor? { image.colorAt(x: Int(x * 2), y: Int(y * 2)) }
        let searchInside = color(metrics.searchLeft + 4, metrics.searchTop + metrics.searchHeight / 2)
        let border = color(metrics.searchLeft + 40, metrics.searchTop + 0.25)
        let underline = color(metrics.tabTitleX + 8, metrics.headerHeight - 1)
        appearance.performAsCurrentDrawingAppearance {
            #expect(searchInside?.isClose(to: Palette.emojiSearchBackground) == true, "Поле: \(String(describing: searchInside))")
            #expect(border?.isClose(to: Palette.focusRing) == true, "Рамка: \(String(describing: border))")
            #expect(underline?.isClose(to: Palette.textPrimary) == true, "Черта: \(String(describing: underline))")
        }
    }
}

private extension NSColor {
    func isClose(to other: NSColor, tolerance: CGFloat = 0.03) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) <= tolerance && abs(a.greenComponent - b.greenComponent) <= tolerance
            && abs(a.blueComponent - b.blueComponent) <= tolerance
    }
}
