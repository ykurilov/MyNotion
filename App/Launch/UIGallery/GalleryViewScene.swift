import AppKit
import DatabaseGrid
import DatabaseViewBar
import Databases
import NotesCore
import PageEditor
import UIGallery
import VisualStyle

/// Вид базы в галерее (US3, T084): эталон «Задачи» (300 задач), вид «Задачи — работа» с фильтром, сортировками и группами;
/// окна вида открываются так же, как от кнопок строки вида.
@MainActor
enum GalleryViewScene {
    private static var panels: ViewPanels?
    private static var menus: PropertyMenuPresenter?

    static func handles(_ kind: GalleryDatabases) -> Bool {
        switch kind {
        case .viewBarActive, .viewFilterSimple, .viewFilterAdvanced, .viewFilterDate, .viewSorts, .viewVisibility, .viewGrouping, .viewGroupedTable,
             .viewWrapText, .viewLayout, .viewSettings, .viewTabMenu, .viewSearch, .viewCalculateMenu: true
        default: false
        }
    }

    static func show(_ kind: GalleryDatabases, model: MainWindowModel, window: NSWindow) async -> String? {
        let store = model.store
        guard let sample = try? DatabaseSampleGenerator(taskCount: 300, projectCount: 20).ensure(in: store) else { return "эталона нет" }
        model.library.reloadTree()
        model.select(sample.tasksId)
        await settle()
        guard let table = GalleryDatabasesScene.find(DatabaseTableView.self, in: window.contentView) else { return "таблица не показана" }
        // Страница-база открывается сверху: прокрутка соседней страницы не переносится.
        GalleryDatabasesScene.find(PageTextView.self, in: window.contentView)?.scroll(NSPoint(x: 0, y: 0))
        await settle()
        let controller = table.controller
        let operations = DatabaseOperations(store: store)
        let property = { (name: String) in sample.taskProperties[name]! }
        let usesWorkView: Set<GalleryDatabases> = [.viewBarActive, .viewFilterSimple, .viewFilterAdvanced, .viewSorts, .viewGrouping,
                                                   .viewGroupedTable, .viewTabMenu, .viewSettings]
        if usesWorkView.contains(kind) { table.switchView(to: sample.workViewId) }
        let panels = ViewPanels(controller: controller)
        self.panels = panels
        let menus = PropertyMenuPresenter(store: store, operations: model.databaseOperations, databaseId: controller.databaseId, viewId: controller.viewId)
        self.menus = menus
        panels.onShowProperties = { rect, host in menus.showPropertiesWindow(below: rect, in: host) }
        let bar = table.convert(table.viewBar.bounds, from: table.viewBar)
        let button = NSRect(x: bar.maxX - 200, y: bar.minY, width: 28, height: bar.height)
        do {
            switch kind {
            case .viewBarActive:
                table.revealChips()
            case .viewFilterSimple:
                table.revealChips()
                panels.showFilter(at: [0], below: chipRect(table, 0), in: table)
            case .viewFilterAdvanced:
                table.revealChips()
                guard let path = FilterEditing.advancedPath(in: controller.view.filterNode) else { return "расширенного фильтра нет" }
                var filter = controller.view.filterNode
                // Вложенная группа — одна (галерея снимает обе темы на одной базе).
                if filter?.node(at: path)?.children.contains(where: \.isGroup) != true {
                    filter = FilterEditing.addGroup(FilterCondition(propertyId: property("Часы"), op: .greaterThan, value: 4), toGroup: path, in: filter)
                    try operations.setFilter(filter, of: controller.viewId)
                }
                table.revealChips()
                panels.showFilter(at: path, below: chipRect(table, path[0]), in: table)
            case .viewFilterDate:
                try operations.setFilter(.condition(FilterCondition(propertyId: property("Срок"), op: .isRelativeToToday,
                                                                    value: ["direction": "this", "count": 1, "unit": "week"])), of: controller.viewId)
                table.revealChips()
                panels.showFilter(at: [0], below: chipRect(table, 0), in: table)
            case .viewSorts:
                table.revealChips()
                panels.showSorts(below: button, in: table)
            case .viewVisibility:
                panels.showPropertyVisibility(below: button, in: table)
            case .viewGrouping:
                panels.showGrouping(below: button, in: table)
            case .viewGroupedTable:
                // Короткие группы оставляют в кадре их итоги и свёрнутую группу, а не только первые 40 строк.
                try operations.setFilter(.condition(FilterCondition(propertyId: property("Часы"), op: .lessThan, value: 2)),
                                         of: controller.viewId)
                let order = controller.groupOrder
                if let first = order.first { try operations.setGroupCollapsed(first, true, order: order, in: controller.viewId) }
                try operations.setCalculation(.countAll, of: property("Название"), in: controller.viewId)
                try operations.setCalculation(.sum, of: property("Часы"), in: controller.viewId)
            case .viewWrapText:
                try operations.setWrap(property("Описание"), true, in: controller.viewId)
                try operations.setColumnWidth(property("Описание"), in: controller.viewId, to: 180)
            case .viewLayout:
                panels.showLayout(below: button, in: table)
            case .viewSettings:
                panels.showViewSettings(in: table, selectName: false)
            case .viewTabMenu:
                guard let tab = table.viewBar.subviews.first(where: { $0.accessibilityLabel() == DatabaseSampleGenerator.workViewName }) else {
                    return "вкладки нет"
                }
                table.viewBar.onTabMenu?(sample.workViewId, tab)
            case .viewSearch:
                table.viewBar.setSearching(true, text: "отчёт")
                controller.setSearch("отчёт")
            case .viewCalculateMenu:
                try operations.setCalculation(.sum, of: property("Часы"), in: controller.viewId)
                try operations.setCalculation(.countAll, of: property("Название"), in: controller.viewId)
                await settle()
                let grid = table.grid
                guard let column = controller.content.columns.firstIndex(where: { $0.property.id == property("Часы") }) else { return "колонки нет" }
                let x = controller.content.columns.prefix(column).reduce(0) { $0 + $1.width }
                let cell = NSRect(x: x, y: grid.fittingHeight - 1 - GridLayout.totalsHeight, width: controller.content.columns[column].width,
                                  height: GridLayout.totalsHeight)
                let rect = table.convert(cell, from: grid)
                // Строка итогов — внизу страницы-базы: долистать до неё, меню — над ней.
                table.scrollToVisible(rect.insetBy(dx: 0, dy: -260))
                await settle()
                menus.showCalculateMenu(for: property("Часы"), below: rect, in: table)
            default:
                return nil
            }
        } catch {
            return "вид не записался: \(error.localizedDescription)"
        }
        await settle()
        return nil
    }

    /// Плашка фильтра в полосе под строкой вида (координаты таблицы).
    private static func chipRect(_ table: DatabaseTableView, _ index: Int) -> NSRect {
        let chips = table.chipsBar.subviews
        guard chips.indices.contains(index) else { return table.convert(table.chipsBar.bounds, from: table.chipsBar) }
        return table.convert(chips[index].frame, from: table.chipsBar)
    }

    static func tearDown() {
        panels?.close()
        panels = nil
        menus?.close()
        menus = nil
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(400))
    }
}
