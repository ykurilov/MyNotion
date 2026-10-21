import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Реестры этапа 0 (plan.md, Structure Decision): меню «•••» страницы собирается из описателей пунктов в порядке
/// contracts/pages-ui.md; шапка страницы разнесена на места «обложка», «кнопки», «название», «под названием» —
/// пустые места не занимают высоты, шапка 001 без обложки не изменилась.
@MainActor
@Suite("Реестры меню «•••» и мест шапки")
struct PageMenusRegistryTests {
    static func item(_ slot: PageMenuSlot, _ title: String, shown: Bool = true) -> PageMenuItem {
        PageMenuItem(slot: slot, title: { _ in title }, isShown: { _ in shown }, kind: .action { _ in })
    }

    let context = PageMenuContext(page: Page(title: "П", sortKey: .between(nil, nil), createdAt: Date(), updatedAt: Date()), wordCount: 12)

    private func layout(_ items: [PageMenuItem]) -> [String] {
        PageMenuLayout.rows(items, context: context).map { row in
            switch row {
            case .separator: "—"
            case .item(let item): item.title(context)
            }
        }
    }

    @Test("Меню «•••» — в порядке контракта, с линиями между группами, в каком бы порядке ни пришли описатели")
    func pageMenuOrder() {
        let all: [PageMenuItem] = [
            Self.item(.footer, "Изменено"), Self.item(.trash, "Удалить в корзину"), Self.item(.appearance, "Вид страницы"),
            Self.item(.versionHistory, "История версий"), Self.item(.template, "Сделать шаблоном"), Self.item(.moveTo, "Переместить в"),
            Self.item(.findAction, "Найти действие…"), Self.item(.duplicate, "Дублировать"),
        ]
        #expect(layout(all) == ["Найти действие…", "Дублировать", "Переместить в", "История версий", "—", "Вид страницы", "—",
                                "Сделать шаблоном", "Удалить в корзину", "—", "Изменено"])
    }

    @Test("Пункты этапа 0: поиск, «Удалить в корзину», подвал — без пустых групп и двойных линий")
    func stageZeroItems() {
        #expect(layout([Self.item(.trash, "Удалить в корзину"), Self.item(.footer, "Изменено"), Self.item(.findAction, "Найти действие…")])
                == ["Найти действие…", "—", "Удалить в корзину", "—", "Изменено"])
        #expect(layout([Self.item(.findAction, "Найти действие…"), Self.item(.trash, "Удалить в корзину", shown: false), Self.item(.footer, "Изменено")])
                == ["Найти действие…", "—", "Изменено"], "скрытый пункт не оставляет линий")
    }

    @Test("Подвал «Изменено: …, N слов» — из контекста страницы")
    func footerText() {
        let now = Date()
        let page = Page(title: "П", sortKey: .between(nil, nil), createdAt: now, updatedAt: now)
        let text = PageMenuFooter.text(for: PageMenuContext(page: page, wordCount: 5), now: now)
        #expect(text.hasPrefix("Изменено: сегодня в "))
        #expect(text.hasSuffix(", 5 слов"))
        #expect(PageMenuFooter.words(1) == "1 слово" && PageMenuFooter.words(3) == "3 слова" && PageMenuFooter.words(11) == "11 слов")
    }

    @Test("«Найти действие…»: остаются пункты с запросом в названии; без запроса — всё меню")
    func searchFiltersItems() {
        let items = [PageMenuItem(slot: .findAction, title: { _ in "Найти действие…" }, kind: .search), Self.item(.duplicate, "Дублировать"),
                     Self.item(.moveTo, "Переместить в"), Self.item(.trash, "Удалить в корзину"),
                     PageMenuItem(slot: .footer, title: { _ in "Изменено" }, kind: .footer)]
        let view = PageMenuView(rows: PageMenuLayout.rows(items, context: context), context: context)
        #expect(view.visibleTitles == ["Дублировать", "Переместить в", "Удалить в корзину"])
        view.filter("уда")
        #expect(view.visibleTitles == ["Удалить в корзину"])
        view.filter("")
        #expect(view.visibleTitles.count == 3)
    }

    @Test("Пункт меню выполняет действие со своей страницей")
    func actionRuns() throws {
        var ran: [UUID] = []
        let item = PageMenuItem(slot: .trash, title: { _ in "Удалить в корзину" }, kind: .action({ ran.append($0.page.id) }, shortcut: "⌘⌫"))
        let view = PageMenuView(rows: PageMenuLayout.rows([item], context: context), context: context)
        let row = try #require(view.actions.rowViews.first)
        row.press()
        #expect(ran == [context.page.id])
    }

    @Test("Подменю «Вид страницы ›» — по середине своей строки, заходит на меню на 4, как у Notion 7.39 (T101 № 11)")
    func appearanceSubmenuPlace() {
        // Меню у правого края экрана; строка «Вид страницы» — в 4 от краёв меню.
        let menu = NSRect(x: 1176, y: 300, width: Metrics.PageMenu.width, height: 400)
        let row = NSRect(x: menu.minX + 4, y: 560, width: menu.width - 8, height: 29)
        let size = NSSize(width: Metrics.PageMenu.submenuWidth, height: 64)
        let card = PageMenuSubmenu.cardFrame(size: size, row: row, screen: NSRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(card.midY == row.midY, "подменю \(card) не по середине строки \(row)")
        #expect(menu.minX - card.maxX == -4, "подменю должно заходить на меню на 4: \(card)")
        // Слева нет места — справа, тоже с заходом на 4.
        let left = NSRect(x: 4, y: 560, width: menu.width - 8, height: 29)
        let right = PageMenuSubmenu.cardFrame(size: size, row: left, screen: NSRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(right.minX == left.maxX)
    }

    @Test("Меню «•••»: значки у всех пунктов, кроме поиска и подвала; ширина 256, как у Notion")
    func pageMenuIcons() throws {
        let items = [PageMenuItem(slot: .findAction, title: { _ in "Найти действие…" }, kind: .search), Self.item(.duplicate, "Дублировать"),
                     Self.item(.moveTo, "Переместить в"), Self.item(.versionHistory, "История версий"), Self.item(.template, "Сделать шаблоном"),
                     Self.item(.trash, "Удалить в корзину"), PageMenuItem(slot: .footer, title: { _ in "Изменено" }, kind: .footer)]
        let view = PageMenuView(rows: PageMenuLayout.rows(items, context: context), context: context)
        #expect(view.fittingSize.width == 256)
        #expect(view.actions.rowViews.allSatisfy { $0.action.icon != nil })
    }

    // MARK: Места шапки

    @Test("Шапка 001 без обложки и без строки под названием — те же рамки, что в 002")
    func headerWithoutSlotsUnchanged() throws {
        for icon in [nil, "📘"] as [String?] {
            let editor = try EditorFixture()
            editor.textView.showIcon(icon)
            let header = editor.textView.header
            header.layoutSubtreeIfNeeded()
            let titleTop = icon == nil ? Metrics.Page.headerTopPaddingWithoutIcon
                : Metrics.Page.headerTopPadding + Metrics.Page.iconSize + Metrics.Page.iconToTitleSpacing
            #expect(header.frame.minY == 0, "обложки нет — шапка у верха")
            #expect(header.titleField.frame.minY == titleTop)
            #expect(header.frame.height == titleTop + header.titleField.frame.height + Metrics.Page.titleToFirstBlockSpacing)
            #expect(editor.textView.textContainerOrigin.y == header.frame.maxY)
        }
    }

    @Test("Место «под названием»: вид занимает свою высоту между названием и первым блоком; пустое — ничего")
    func underTitleSlot() throws {
        let editor = try EditorFixture()
        let header = editor.textView.header
        header.layoutSubtreeIfNeeded()
        let before = header.frame.height
        let line = NSView()
        editor.textView.setUnderTitle(line, height: 24)
        header.layoutSubtreeIfNeeded()
        #expect(header.frame.height == before + 24)
        #expect(line.frame.minY == header.titleField.frame.maxY)
        #expect(line.frame.height == 24)
        editor.textView.setUnderTitle(nil, height: 24)
        header.layoutSubtreeIfNeeded()
        #expect(header.frame.height == before)
        #expect(line.superview == nil)
    }

    @Test("Место «обложка»: текст и шапка ниже на высоту обложки; без обложки — на месте")
    func coverSlot() throws {
        let editor = try EditorFixture()
        let originBefore = editor.textView.textContainerOrigin.y
        let cover = NSView()
        editor.textView.setCover(cover, height: 280)
        #expect(editor.textView.header.frame.minY == 280)
        // Без иконки название под обложкой со своим полем (US1, «Шапка страницы»), а не с полем страницы без обложки.
        let titleShift = Metrics.Page.headerTopPaddingWithCover - Metrics.Page.headerTopPaddingWithoutIcon
        #expect(editor.textView.textContainerOrigin.y == originBefore + 280 + titleShift)
        #expect(cover.frame == NSRect(x: 0, y: 0, width: editor.textView.bounds.width, height: 280))
        editor.textView.setCover(nil, height: 280)
        #expect(editor.textView.textContainerOrigin.y == originBefore)
    }

    @Test("Место «кнопки»: кнопки в строку над названием, скрытые не занимают места")
    func buttonsSlot() throws {
        let editor = try EditorFixture()
        let header = editor.textView.header
        let cover = PageHeaderButton(symbolName: "photo", title: "Добавить обложку", identifier: "add-page-cover")
        header.addButton(cover)
        header.isHovered = true
        header.layoutSubtreeIfNeeded()
        let icon = header.addIconButton
        #expect(!icon.isHidden && !cover.isHidden)
        #expect(cover.frame.minY == icon.frame.minY)
        #expect(cover.frame.minX >= icon.frame.maxX)
        editor.textView.showIcon("📘")
        header.layoutSubtreeIfNeeded()
        #expect(icon.isHidden)
        #expect(cover.frame.minX == icon.frame.minX, "«Добавить иконку» скрыта — обложка встаёт на её место")
    }
}

/// Список обратных ссылок открывается под строкой «↗ N обратных ссылок» левым краем по ней (T101 № 6).
@MainActor
@Suite("Место списка обратных ссылок")
struct BacklinksListPlaceTests {
    @Test("Якорь списка — под строкой на 4, у её левого края, а не по середине строки во всю ширину страницы")
    func anchorUnderRowStart() {
        let row = BacklinksRow(title: "3 обратные ссылки")
        row.frame = NSRect(x: 0, y: 0, width: 720, height: BacklinksRow.height)
        #expect(row.listAnchor == NSPoint(x: 0, y: BacklinksRow.height + 4))
        #expect(row.listAnchor.x < row.fittingWidth, "якорь левее конца текста строки")
    }
}
