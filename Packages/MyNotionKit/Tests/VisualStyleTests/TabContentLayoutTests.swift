import CoreGraphics
import Testing
@testable import VisualStyle

/// Что видно во вкладке, как у Notion 7.39 (замер 21.10.2026: 14 вкладок по 76,6 и 25 по 41,2; проверка T101 № 3, 22).
@Suite("Содержимое вкладки по ширине")
struct TabContentLayoutTests {
    @Test("Широкая вкладка: поля 16, место под «×» — только под мышью")
    func wideTab() {
        let idle = TabContentLayout(width: Metrics.Tabs.tabWidth, hasIcon: true, isHovered: false)
        #expect(idle.inset == 16)
        #expect(idle.titleWidth == Metrics.Tabs.tabWidth - 32 - 15 - 8)
        let hovered = TabContentLayout(width: Metrics.Tabs.tabWidth, hasIcon: true, isHovered: true)
        #expect(hovered.titleWidth < idle.titleWidth, "под мышью название уступает место «×»")
        #expect(abs(idle.titleWidth - hovered.titleWidth - 15) < 0.01, "«×» серединой в 17 от края, кнопка 20, зазор 4")
    }

    @Test("Как у Notion при 76,6: иконка и кусок названия; без иконки — название с края")
    func notionAt77() {
        let withIcon = TabContentLayout(width: 76.6, hasIcon: true, isHovered: false)
        #expect(withIcon.inset == 16 && withIcon.showsTitle)
        let plain = TabContentLayout(width: 76.6, hasIcon: false, isHovered: false)
        #expect(abs(plain.titleWidth - 44.6) < 0.01)
    }

    @Test("Самая узкая вкладка (40): с иконкой — одна иконка; без иконки — кусок названия, активная не пустая")
    func narrowestTab() {
        let width = Metrics.Tabs.minimumTabWidth
        let withIcon = TabContentLayout(width: width, hasIcon: true, isHovered: false)
        #expect(withIcon.inset == 10, "поле узкой вкладки — четверть ширины, как у Notion (10,3 при 41,2)")
        #expect(!withIcon.showsTitle, "буквы рядом с иконкой режутся — у Notion их нет")
        #expect(withIcon.inset + Metrics.Tabs.iconSize <= width, "иконка влезает целиком")
        let plain = TabContentLayout(width: width, hasIcon: false, isHovered: false)
        #expect(plain.titleWidth == 20, "у Notion при 41,2 — 20,6 названия")
    }

    @Test("Ширины от 40 до 199: иконка и название не вылезают за вкладку")
    func neverOverflows() {
        for width in stride(from: Metrics.Tabs.minimumTabWidth, through: Metrics.Tabs.tabWidth, by: 1) {
            for hasIcon in [true, false] {
                for hovered in [true, false] {
                    let layout = TabContentLayout(width: width, hasIcon: hasIcon, isHovered: hovered)
                    let used = layout.inset + (hasIcon ? Metrics.Tabs.iconSize + (layout.showsTitle ? Metrics.Tabs.iconTitleGap : 0) : 0)
                        + layout.titleWidth
                    #expect(used <= width - (layout.showsTitle ? layout.inset : 0) + 0.01, "ширина \(width): занято \(used)")
                    if !hasIcon, !hovered { #expect(layout.showsTitle, "вкладка \(width) без иконки пустая") }
                }
            }
        }
    }
}
