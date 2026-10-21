import AppKit
import NotesCore
import SwiftUI
import Testing
import VisualStyle
@testable import PageTree

/// Геометрия боковой панели и окна корзины по contracts/visual-style.md и проверке интерфейса 15.10.2026
/// (ui-review, №1, 2, 14, 15, 16, 17). Меряется то, что видно: нарисованные пиксели и рамки окон.
@MainActor
@Suite("Геометрия боковой панели и корзины")
struct SidebarGeometryTests {
    // MARK: Окно корзины (№1, 14)

    @Test("Окно корзины справа от панели, целиком в окне, при 1440×900 и 900×700", arguments: [
        NSSize(width: 1440, height: 900), NSSize(width: 900, height: 700),
    ])
    func trashPanelStaysInsideWindow(windowSize: NSSize) {
        let sidebarMaxX = Metrics.Sidebar.defaultWidth
        let anchor = Self.trashRowFrame(sidebarWidth: sidebarMaxX)
        for entryCount in [0, 3, 100] {
            let card = TrashPanelLayout.cardFrame(windowSize: windowSize, sidebarMaxX: sidebarMaxX, anchorRow: anchor,
                                                  contentHeight: TrashView.preferredHeight(entryCount: entryCount))
            let margin = Metrics.TrashPanel.windowMargin
            #expect(card.minX >= sidebarMaxX + Metrics.TrashPanel.sidebarGap, "залезает на панель: \(card)")
            #expect(card.maxX <= windowSize.width - margin, "выходит справа: \(card)")
            #expect(card.minY >= margin, "выходит снизу: \(card)")
            #expect(card.maxY <= windowSize.height - margin, "выходит сверху: \(card)")
            #expect(card.minY <= anchor.minY + 0.5, "не стоит у строки «Корзина»: \(card)")
        }
    }

    @Test("Пустая корзина — то же окно той же ширины, содержимое от того же левого края")
    func emptyTrashKeepsWidth() {
        let size = NSSize(width: 1440, height: 900)
        let anchor = Self.trashRowFrame(sidebarWidth: Metrics.Sidebar.defaultWidth)
        let empty = TrashPanelLayout.cardFrame(windowSize: size, sidebarMaxX: Metrics.Sidebar.defaultWidth, anchorRow: anchor,
                                               contentHeight: TrashView.preferredHeight(entryCount: 0))
        let full = TrashPanelLayout.cardFrame(windowSize: size, sidebarMaxX: Metrics.Sidebar.defaultWidth, anchorRow: anchor,
                                              contentHeight: TrashView.preferredHeight(entryCount: 3))
        #expect(empty.minX == full.minX)
        #expect(empty.width == full.width)
        #expect(empty.width == Metrics.TrashPanel.width)
    }

    @Test("Окно корзины рисует скругление, рамку и тень вокруг карточки")
    func trashPanelDrawsChrome() throws {
        let surface = TrashPanelSurfaceView(cardSize: NSSize(width: Metrics.TrashPanel.width, height: 200))
        let card = surface.cardRect
        // Тень под карточкой: пиксели ниже карточки не пустые.
        let shadowed = try Self.render(surface)
        #expect(shadowed.alpha(atX: card.midX, y: card.maxY + 4, flipped: true) > 0.005, "нет тени")
        // В самом углу карточки — скругление: пиксель угла пустой или почти.
        #expect(shadowed.alpha(atX: card.minX + 0.5, y: card.minY + 0.5, flipped: true) < 0.5, "нет скругления")
        // Рамка в тёмной теме видна: на странице, как её видит глаз, край ярче страницы рядом за ним.
        let onPage = PageBackdrop(surface: surface)
        onPage.appearance = NSAppearance(named: .darkAqua)
        let bitmap = try Self.render(onPage)
        let ring = bitmap.color(atX: card.minX - 0.5, y: card.midY, flipped: true)
        let outside = bitmap.color(atX: card.minX - 3, y: card.midY, flipped: true)
        #expect(ring.brightness - outside.brightness > 0.03, "рамки не видно: \(ring) и \(outside)")
    }

    @Test("Верхний край окна корзины отделён от страницы: тень над краем и видимая рамка (№ 26)",
          arguments: [NSAppearance.Name.aqua, .darkAqua])
    func trashPanelTopEdgeStandsOut(_ theme: NSAppearance.Name) throws {
        let surface = TrashPanelSurfaceView(cardSize: NSSize(width: Metrics.TrashPanel.width, height: 200))
        let onPage = PageBackdrop(surface: surface)
        onPage.appearance = NSAppearance(named: theme)
        let bitmap = try Self.render(onPage)
        let card = surface.cardRect
        let page = bitmap.color(atX: 2, y: 2, flipped: true).brightness
        let ring = bitmap.color(atX: card.midX, y: card.minY - 0.5, flipped: true).brightness
        let halo = bitmap.color(atX: card.midX, y: card.minY - 2, flipped: true).brightness
        // Рамка заметно отличается от страницы (в светлой — темнее, в тёмной — светлее).
        #expect(abs(ring - page) > 0.05, "рамка сливается со страницей: \(ring) и \(page)")
        // Над краем — мягкая тень, а не резкий срез строки: страница у края темнее, чем вдали.
        #expect(page - halo > 0.02, "над краем нет тени: \(halo) и \(page)")
    }

    // MARK: Строки дерева (№16, 17)

    @Test("Значок документа и эмодзи — центры на одной вертикали")
    func iconsShareCenter() throws {
        let (outline, _) = Self.outline(pages: [Self.page("С иконкой", icon: "📘", key: "1"), Self.page("Без иконки", key: "2")])
        let emoji = try Self.iconInk(outline, row: 0)
        let document = try Self.iconInk(outline, row: 1)
        #expect(abs(emoji.midX - document.midX) <= 0.75, "эмодзи \(emoji), документ \(document)")
        #expect(abs(emoji.midX - (Metrics.Sidebar.rowHorizontalPadding + Metrics.Sidebar.rowIconSize / 2)) <= 0.75,
                "эмодзи не по центру квадрата иконки: \(emoji)")
    }

    @Test("«⋯» и «+» — одного размера и цвета, справа поле строки")
    func accessoriesMatch() throws {
        let (outline, _) = Self.outline(pages: [Self.page("Проекты", key: "1")])
        let cell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? PageTreeCellView)
        cell.isRowHovered = true
        cell.layoutSubtreeIfNeeded()
        let bitmap = try Self.render(cell)
        let menu = try #require(bitmap.inkBounds(in: cell.menuButton.frame, flipped: cell.isFlipped))
        let add = try #require(bitmap.inkBounds(in: cell.addButton.frame, flipped: cell.isFlipped))
        #expect(abs(menu.width - add.width) <= 2.5, "«⋯» \(menu.width), «+» \(add.width)")
        #expect(cell.menuButton.contentTintColor == cell.addButton.contentTintColor)
        // Читаются на светлой панели: цвет второстепенного текста, а не бледный цвет ручек блока.
        #expect(cell.addButton.contentTintColor == Palette.textSecondary)
        #expect(abs(menu.midY - add.midY) <= 0.75, "не на одной высоте: \(menu) и \(add)")
        #expect(cell.bounds.maxX - cell.addButton.frame.maxX == Metrics.Sidebar.rowHorizontalPadding)
    }

    @Test("Дерево не шире панели: «⋯ +» строк видны целиком и с тремя уровнями вложенности, и после смены ширины",
          arguments: [Metrics.Sidebar.defaultWidth, Metrics.Sidebar.defaultWidth + 120])
    func outlineFitsSidebar(width: CGFloat) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Metrics.Sidebar.defaultWidth, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let projects = Self.page("Проекты", key: "1")
        let app = Self.page("MyNotion", parent: projects.id, key: "1")
        let notes = Self.page("Заметки", parent: app.id, key: "1")
        let actions = PageTreeActions(select: { _ in }, rename: { _, _ in }, move: { _, _, _ in }, moveToTrash: { _ in },
                                      addSubpage: { _ in }, collapsedPagesChanged: { _ in })
        // Как ⌘N «Проекты», ⇧⌘N «MyNotion», ⇧⌘N «Заметки»: ветки раскрываются, когда дерево уже на экране.
        let steps = [[projects], [projects, app], [projects, app, notes]]
        let host = NSHostingView(rootView: Self.sidebar(steps[0], revision: 0, actions: actions))
        window.contentView = host
        for (revision, pages) in steps.enumerated() {
            host.rootView = Self.sidebar(pages, revision: revision, actions: actions)
            host.layoutSubtreeIfNeeded()
        }
        window.setContentSize(NSSize(width: width, height: 400))
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try #require(Self.find(PageOutlineView.self, in: content))
        let clip = try #require(outline.enclosingScrollView?.contentView)
        #expect(outline.numberOfRows == 3)
        #expect(abs(outline.frame.width - clip.bounds.width) <= 0.5, "дерево \(outline.frame.width), видно \(clip.bounds.width)")
        for row in 0..<outline.numberOfRows {
            let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? PageTreeCellView)
            cell.layoutSubtreeIfNeeded()
            let addButton = cell.convert(cell.addButton.frame, to: clip)
            #expect(clip.bounds.contains(addButton), "строка \(row): «+» за краем \(addButton), видно \(clip.bounds)")
        }
    }

    @Test("Списки панели: поле 15 справа под полосу у всех разделов, полоса поверх, сверху затухание только у прокрученного (T101 № 7, 8)")
    func sidebarListsShareWidthAndFadeOnScroll() throws {
        let width = Metrics.Sidebar.defaultWidth - 2 * Metrics.Sidebar.panelInset
        let scroll = SidebarScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1000))
        scroll.documentView = document
        scroll.layoutSubtreeIfNeeded()
        // Строки кончаются на 247 при панели 270, как у Notion, — и в «Недавних», где прокрутки нет, и в «Страницах».
        #expect(Metrics.Sidebar.panelInset + scroll.contentView.frame.width == 247, "видно \(scroll.contentView.frame)")
        #expect(scroll.scrollerStyle == .overlay)
        scroll.scrollerStyle = .legacy
        #expect(scroll.scrollerStyle == .overlay, "полоса сбоку сузила бы дерево против разделов")
        #expect(!scroll.isTopFaded, "у верха списка затухания нет")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        scroll.layoutSubtreeIfNeeded()
        #expect(scroll.isTopFaded, "прокрученный список не гаснет сверху")
        let mask = try #require(scroll.layer?.mask as? CAGradientLayer)
        // Слой перевёрнут: верх — y = 0; прозрачно у верха, сплошь — с 34.
        #expect(mask.startPoint.y == 0)
        #expect(abs(mask.endPoint.y * scroll.bounds.height - Metrics.Sidebar.scrollTopFadeHeight) < 0.5)
        scroll.contentView.scroll(to: .zero)
        scroll.layoutSubtreeIfNeeded()
        #expect(!scroll.isTopFaded)
    }

    // MARK: Переименование (№2)

    @Test("Переименование: текст не сдвигается, поле прозрачное", arguments: ["Заметки", ""])
    func renamingKeepsTextInPlace(title: String) throws {
        let (outline, window) = Self.outline(pages: [Self.page(title.isEmpty ? "Без названия" : title, key: "1")])
        let cell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? PageTreeCellView)
        let titleArea = Self.titleArea(of: cell)
        let before = try #require(Self.render(cell).inkBounds(in: titleArea, flipped: cell.isFlipped))

        let editing = try Self.renderRenaming(cell, in: window)
        let during = try #require(editing.inkBounds(in: titleArea, flipped: cell.isFlipped))
        #expect(abs(during.minX - before.minX) <= 0.75, "текст сдвинулся: \(before.minX) → \(during.minX)")
        #expect(abs(during.midY - before.midY) <= 0.75, "текст сдвинулся по высоте: \(before.midY) → \(during.midY)")
        // Без белой плашки: справа от текста в поле — пусто.
        #expect(editing.alpha(atX: during.maxX + 20, y: during.midY, flipped: cell.isFlipped) < 0.05, "у поля свой фон")
    }

    @Test("Переименование длинного названия: текст кончается за 8 до края строки")
    func renamingLongTitleKeepsRightPadding() throws {
        let (outline, window) = Self.outline(pages: [Self.page("Работа над приложением заметок для Mac и всех устройств сразу", key: "1")])
        let cell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? PageTreeCellView)
        let editing = try Self.renderRenaming(cell, in: window)
        let during = try #require(editing.inkBounds(in: Self.titleArea(of: cell), flipped: cell.isFlipped))
        #expect(cell.bounds.maxX - during.maxX >= Metrics.Sidebar.rowHorizontalPadding - 0.5, "текст до края строки: \(during)")
        #expect(during.minX >= Metrics.Sidebar.rowHorizontalPadding + Metrics.Sidebar.rowIconSize + 1, "текст залез на иконку: \(during)")
    }

    // MARK: Как в Notion для Mac (снимок 15.10.2026, тёмная тема)

    @Test("Строка дерева: шаг 31, подсветка 30, квадрат иконки 22, текст через 8 от него, обычная жирность")
    func rowMatchesNotion() throws {
        let (outline, _) = Self.outline(pages: [Self.page("Первая", key: "1"), Self.page("Вторая", key: "2")])
        #expect(outline.rect(ofRow: 1).minY - outline.rect(ofRow: 0).minY == 31)
        let rowView = try #require(outline.rowView(atRow: 0, makeIfNecessary: true) as? PageTreeRowView)
        #expect(rowView.highlightRect.height == 30)
        #expect(rowView.highlightRect.midY == rowView.bounds.midY)
        let cell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? PageTreeCellView)
        cell.layoutSubtreeIfNeeded()
        // Отступ панели 8 + поле строки 8: квадрат иконки 16…38, текст с 46 от края панели.
        #expect(cell.documentIcon.frame == NSRect(x: 8, y: (cell.bounds.height - 22) / 2, width: 22, height: 22))
        #expect(abs(cell.titleLabel.alignmentRect(forFrame: cell.titleLabel.frame).minX - (8 + 22 + 8)) <= 0.01)
        #expect(cell.titleLabel.font == NSFont.systemFont(ofSize: 14, weight: .regular))
    }

    @Test("Цвета панели в тёмной теме — по снимку Notion: текст строк, значки, заголовок группы")
    func darkColorsMatchNotion() {
        let dark = NSAppearance(named: .darkAqua)!
        func hex(_ color: NSColor) -> String {
            var result = ""
            dark.performAsCurrentDrawingAppearance {
                let rgb = color.usingColorSpace(.sRGB)!
                result = String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                                Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            }
            return result
        }
        #expect(hex(Palette.sidebarText) == "BCBAB7")
        #expect(hex(Palette.sidebarIcon) == "9B9A97")
        #expect(hex(Palette.sidebarGroupHeader) == "7C7A76")
        #expect(hex(Palette.windowToolbarIcon) == "ACA9A4")
    }

    @Test("Верхняя строка панели — в линию со светофором: «✎» справа; заголовок группы и дерево сразу под ней")
    func topRowMatchesNotion() throws {
        let width = Metrics.Sidebar.defaultWidth
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: Self.sidebar([Self.page("Проекты", key: "1")], revision: 0, actions: Self.noActions))
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let titleBar = Metrics.Window.titleBarHeight
        #expect(titleBar == 36)
        // «✎»: нарисованный значок по центру квадрата у правого края, на середине строки светофора.
        let bitmap = try Self.render(host)
        let button = Metrics.Window.toolbarButtonSize
        let box = NSRect(x: width - Metrics.Sidebar.panelInset - button, y: (titleBar - button) / 2, width: button, height: button)
        let background = bitmap.color(atX: width / 2, y: 2, flipped: true).brightness
        let ink = try #require(bitmap.bounds(in: NSRect(x: width / 2, y: 0, width: width / 2, height: titleBar), flipped: true) {
            abs($0.brightness - background) > 0.15
        })
        #expect(abs(ink.midX - box.midX) <= 1, "«✎» \(ink), квадрат \(box)")
        #expect(abs(ink.midY - box.midY) <= 1, "«✎» \(ink), квадрат \(box)")
        #expect((12...15).contains(ink.width) && (12...15).contains(ink.height), "«✎» \(ink.size), у Notion 13,5 × 13,5")

        let outline = try #require(Self.find(PageOutlineView.self, in: host))
        let scroll = try #require(outline.enclosingScrollView)
        let listTop = 400 - scroll.convert(scroll.bounds, to: nil).maxY
        #expect(abs(listTop - (titleBar + Metrics.Sidebar.rowHeight)) <= 0.5, "дерево начинается на \(listTop)")
    }

    @Test("Поле поиска — под строкой светофора, на 10 от краёв панели; заголовок группы и дерево — под ним")
    func searchFieldBelowTopRow() throws {
        let width = Metrics.Sidebar.defaultWidth
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let pages = [Self.page("Проекты", key: "1")]
        let sidebar = PageTreeSidebar(tree: PageTreeSnapshot(allPages: pages), treeRevision: 0, collapsedPageIds: [],
                                      selectedPageId: nil, liveTitle: nil, trashEntries: [], actions: Self.noActions,
                                      trashActions: TrashActions(restore: { _ in }, deleteForever: { _ in }, emptyTrash: {}),
                                      newPage: {}) { SearchFieldStandIn() }
        let host = NSHostingView(rootView: sidebar)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let field = try #require(Self.find(SearchFieldStandIn.View.self, in: host))
        let frame = field.convert(field.bounds, to: nil)
        let fieldTop = 400 - frame.maxY
        let search = Metrics.SearchField.self
        #expect(abs(fieldTop - (Metrics.Window.titleBarHeight + search.topSpacing)) <= 0.5, "поле с \(fieldTop)")
        #expect(abs(frame.height - search.height) <= 0.5)
        #expect(abs(frame.minX - 10) <= 0.5 && abs(width - frame.maxX - 10) <= 0.5, "поле \(frame)")

        let outline = try #require(Self.find(PageOutlineView.self, in: host))
        let scroll = try #require(outline.enclosingScrollView)
        let listTop = 400 - scroll.convert(scroll.bounds, to: nil).maxY
        let expected = fieldTop + search.height + search.bottomSpacing + Metrics.Sidebar.rowHeight
        #expect(abs(listTop - expected) <= 0.5, "дерево начинается на \(listTop)")
    }

    // MARK: Помощники

    /// Вместо настоящего поля поиска — пустой вид: панель отводит место любому полю.
    private struct SearchFieldStandIn: NSViewRepresentable {
        final class View: NSView {}
        func makeNSView(context: Context) -> View { View() }
        func updateNSView(_ nsView: View, context: Context) {}
    }

    private static func trashRowFrame(sidebarWidth: CGFloat) -> NSRect {
        NSRect(x: Metrics.Sidebar.panelInset, y: Metrics.Sidebar.footerBottomInset,
               width: sidebarWidth - 2 * Metrics.Sidebar.panelInset, height: Metrics.Sidebar.rowHeight)
    }

    private static func page(_ title: String, icon: String? = nil, parent: UUID? = nil, key: String) -> Page {
        var page = Page(title: title, parentId: parent, sortKey: FractionalSortKey(rawValue: key)!, createdAt: .now, updatedAt: .now)
        page.icon = icon
        return page
    }

    private static func outline(pages: [Page]) -> (PageOutlineView, NSWindow) {
        let width = Metrics.Sidebar.defaultWidth - 2 * Metrics.Sidebar.panelInset
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let outline = PageOutlineView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
        let dataSource = PageOutlineDataSource(actions: PageTreeActions(select: { _ in }, rename: { _, _ in }, move: { _, _, _ in },
                                                                        moveToTrash: { _ in }, addSubpage: { _ in },
                                                                        collapsedPagesChanged: { _ in }))
        dataSource.attach(to: outline)
        window.contentView = outline
        dataSource.show(PageTreeSnapshot(allPages: pages), collapsedPageIds: [], selectedPageId: nil)
        outline.deselectAll(nil)
        outline.tableColumns.first?.width = width
        outline.layoutSubtreeIfNeeded()
        retained.append(dataSource)
        return (outline, window)
    }

    /// Источник данных дерева держится слабо: живёт до конца прогона.
    private static var retained: [AnyObject] = []

    private static func sidebar(_ pages: [Page], revision: Int, actions: PageTreeActions,
                                newPage: @escaping () -> Void = {}) -> PageTreeSidebar<EmptyView> {
        PageTreeSidebar(tree: PageTreeSnapshot(allPages: pages), treeRevision: revision, collapsedPageIds: [],
                        selectedPageId: pages.last?.id, liveTitle: nil, trashEntries: [], actions: actions,
                        trashActions: TrashActions(restore: { _ in }, deleteForever: { _ in }, emptyTrash: {}), newPage: newPage)
    }

    private static let noActions = PageTreeActions(select: { _ in }, rename: { _, _ in }, move: { _, _, _ in },
                                                   moveToTrash: { _ in }, addSubpage: { _ in }, collapsedPagesChanged: { _ in })

    private static func find<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        (view as? View) ?? view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    private static func titleArea(of cell: PageTreeCellView) -> NSRect {
        NSRect(x: cell.titleLabel.frame.minX - 6, y: 0, width: cell.bounds.width - cell.titleLabel.frame.minX + 6, height: cell.bounds.height)
    }

    /// Снимок строки в режиме переименования, курсор в конце (без подсветки выделения).
    private static func renderRenaming(_ cell: PageTreeCellView, in window: NSWindow) throws -> Bitmap {
        cell.beginRenaming()
        let editor = try #require(cell.renameField.currentEditor())
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        window.displayIfNeeded()
        return try render(cell)
    }

    private static func iconInk(_ outline: PageOutlineView, row: Int) throws -> NSRect {
        let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? PageTreeCellView)
        cell.layoutSubtreeIfNeeded()
        let area = NSRect(x: 0, y: 0, width: cell.titleLabel.frame.minX - 1, height: cell.bounds.height)
        return try #require(try render(cell).inkBounds(in: area, flipped: cell.isFlipped))
    }

    static func render(_ view: NSView) throws -> Bitmap {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return Bitmap(rep: bitmap, size: view.bounds.size)
    }
}

/// Пиксели снимка вида в точках вида.
/// Окно корзины поверх страницы: так его видит глаз (на прозрачном фоне тёмная тень искажает край).
final class PageBackdrop: NSView {
    init(surface: NSView) {
        super.init(frame: surface.bounds)
        addSubview(surface)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Palette.pageBackground.setFill()
        bounds.fill()
    }
}

struct Bitmap {
    let rep: NSBitmapImageRep
    let size: NSSize

    private var scale: CGFloat { CGFloat(rep.pixelsWide) / size.width }

    private func pixel(x: CGFloat, y: CGFloat, flipped: Bool) -> NSColor? {
        let px = Int(x * scale), rowFromTop = Int((flipped ? y : size.height - y) * scale)
        guard px >= 0, px < rep.pixelsWide, rowFromTop >= 0, rowFromTop < rep.pixelsHigh else { return nil }
        return rep.colorAt(x: px, y: rowFromTop)?.usingColorSpace(.deviceRGB)
    }

    func alpha(atX x: CGFloat, y: CGFloat, flipped: Bool) -> CGFloat {
        pixel(x: x, y: y, flipped: flipped)?.alphaComponent ?? 0
    }

    func color(atX x: CGFloat, y: CGFloat, flipped: Bool) -> NSColor {
        pixel(x: x, y: y, flipped: flipped) ?? .clear
    }

    /// Рамка нарисованного (непрозрачного) внутри `rect`, в точках вида.
    func inkBounds(in rect: NSRect, flipped: Bool) -> NSRect? {
        bounds(in: rect, flipped: flipped) { $0.alphaComponent > 0.3 }
    }

    /// Рамка пикселей внутри `rect`, подходящих под `isInk`, в точках вида.
    func bounds(in rect: NSRect, flipped: Bool, where isInk: (NSColor) -> Bool) -> NSRect? {
        let step = 1 / scale
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                if isInk(color(atX: x, y: y, flipped: flipped)) {
                    minX = min(minX, x); maxX = max(maxX, x + step)
                    minY = min(minY, y); maxY = max(maxY, y + step)
                }
                x += step
            }
            y += step
        }
        return minX.isFinite ? NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) : nil
    }
}

extension NSColor {
    var brightness: CGFloat {
        let rgb = usingColorSpace(.deviceRGB) ?? self
        return (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3 * rgb.alphaComponent
    }
}
