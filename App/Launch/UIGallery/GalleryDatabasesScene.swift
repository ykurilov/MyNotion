import AppKit
import DatabaseGrid
import DatabaseViewBar
import Databases
import NotesCore
import PageEditor
import UIGallery
import VisualStyle

/// Базы в галерее (этап 0 — T029, US1 — T044): страница-база и встроенная база настоящим переходом, таблица эталона
/// (уменьшенного: 300 задач) в работе — наведение, выделение, правка ячейки, меню и окна свойств, меню строки,
/// страница строки на всю страницу, сбоку и по центру.
@MainActor
enum GalleryDatabasesScene {
    private static var menus: PropertyMenuPresenter?

    static func show(_ kind: GalleryDatabases, model: MainWindowModel, window: NSWindow) async -> String? {
        if GalleryFormulasScene.handles(kind) { return await GalleryFormulasScene.show(kind, model: model, window: window) }
        if GalleryRelationsScene.handles(kind) { return await GalleryRelationsScene.show(kind, model: model, window: window) }
        if GalleryViewScene.handles(kind) { return await GalleryViewScene.show(kind, model: model, window: window) }
        if GalleryTypesScene.handles(kind) { return await GalleryTypesScene.show(kind, model: model, window: window) }
        if GalleryRowTemplatesScene.handles(kind) { return await GalleryRowTemplatesScene.show(kind, model: model, window: window) }
        let store = model.store
        do {
            switch kind {
            case .empty:
                let created = try DatabaseOperations(store: store).createDatabase(in: nil, isInline: false)
                model.library.reloadTree()
                model.select(created.databaseId)
                await settle()
                return nil
            case .inlineEmpty:
                let host = try store.write { tx throws in try tx.createPage(title: "Проект") }
                let anchor = try store.write { tx throws in try tx.blocks(ofPage: host.id)[0].id }
                _ = try DatabaseOperations(store: store).createDatabase(in: host.id, isInline: true, linkAt: .replacing(blockId: anchor))
                model.library.reloadTree()
                model.select(host.id)
                await settle()
                window.makeFirstResponder(nil)
                return nil
            case .inlineOverview:
                let sample = try DatabaseSampleGenerator(taskCount: 300, projectCount: 20).ensure(in: store)
                model.library.reloadTree()
                model.select(sample.overviewId)
                await settle()
                // База в середине длинной страницы: её вид появляется, когда строка блока видна, — листаем до неё.
                var found = find(DatabaseTableView.self, in: window.contentView)
                if found == nil, let page = find(PageTextView.self, in: window.contentView) {
                    for step in 1...40 where found == nil {
                        page.scroll(NSPoint(x: 0, y: CGFloat(step) * 600))
                        try? await Task.sleep(for: .milliseconds(60))
                        found = find(DatabaseTableView.self, in: window.contentView)
                    }
                }
                guard let table = found else { return "встроенной базы нет" }
                table.scrollToVisible(table.bounds)
                await settle()
                window.makeFirstResponder(nil)
                return nil
            default:
                break
            }
        } catch {
            return "база не записалась: \(error.localizedDescription)"
        }
        guard let sample = try? DatabaseSampleGenerator(taskCount: 300, projectCount: 20).ensure(in: store) else { return "эталона нет" }
        model.library.reloadTree()
        model.select(sample.tasksId)
        await settle()
        guard let table = find(DatabaseTableView.self, in: window.contentView) else { return "таблица не показана" }
        // Страница-база открывается сверху, как в приложении: прокрутка соседней страницы не переносится.
        find(PageTextView.self, in: window.contentView)?.scroll(NSPoint(x: 0, y: 0))
        await settle()
        let grid = table.grid
        let controller = table.controller
        let rowId = { (row: Int) in controller.content.rowId(at: row) }
        switch kind {
        case .sampleTable: window.makeFirstResponder(nil)
        case .rowHover:
            grid.showHover(row: 1)
        case .cellSelection:
            grid.selectRange(from: CellPosition(row: 1, column: 1), to: CellPosition(row: 4, column: 3))
        case .cellEditing:
            grid.select(CellPosition(row: 2, column: 0))
            grid.beginEditing()
        case .columnMenu, .deleteConfirm, .editProperty:
            guard controller.content.columns.count > 2 else { return "мало колонок" }
            let property = controller.content.columns[2].property
            let presenter = PropertyMenuPresenter(store: store, operations: model.databaseOperations, databaseId: controller.databaseId,
                                                  viewId: controller.viewId)
            menus = presenter
            let rect = table.convert(grid.cellRect(row: 0, column: 2), from: grid).offsetBy(dx: 0, dy: -Metrics.DatabaseGrid.rowHeight)
            switch kind {
            case .columnMenu: presenter.showColumnMenu(for: property.id, below: rect, in: table)
            case .deleteConfirm:
                presenter.showColumnMenu(for: property.id, below: rect, in: table)
                presenter.confirmDelete(property)
            default: presenter.showEditProperty(property.id, in: table)
            }
        case .typePicker:
            let presenter = PropertyMenuPresenter(store: store, operations: model.databaseOperations, databaseId: controller.databaseId,
                                                  viewId: controller.viewId)
            menus = presenter
            let width = grid.tableWidth
            presenter.showAddProperty(below: NSRect(x: min(width, table.bounds.width - 400), y: ViewBarView.height, width: 32,
                                                    height: Metrics.DatabaseGrid.headerHeight), in: table)
        case .propertiesWindow:
            let presenter = PropertyMenuPresenter(store: store, operations: model.databaseOperations, databaseId: controller.databaseId,
                                                  viewId: controller.viewId)
            menus = presenter
            presenter.showPropertiesWindow(below: NSRect(x: table.bounds.width - 300, y: 0, width: 32, height: ViewBarView.height), in: table)
        case .rowMenu:
            grid.select(CellPosition(row: 2, column: 0))
            // Как правый щелчок: точка внутри ячейки, а не на её нижней границе.
            let cell = grid.cellRect(row: 2, column: 0)
            grid.onRowMenu?(2, NSPoint(x: cell.minX + 60, y: cell.midY))
        case .rowsSelected:
            grid.selectRows([1, 2, 3])
        case .searchNoResults:
            table.viewBar.setSearching(true, text: "яяяя")
            controller.setSearch("яяяя")
        case .rowPage, .sidePeek, .centerPeek:
            guard let row = rowId(1) else { return "строки нет" }
            model.openRow(row, mode: kind == .rowPage ? .fullPage : kind == .sidePeek ? .sidePeek : .centerPeek)
            await settle()
            window.makeFirstResponder(nil)
        case .empty, .inlineEmpty, .inlineOverview, .formulaEditorEmpty, .formulaEditorResult, .formulaEditorError, .formulaEditorCycle,
             .formulaCells, .relationNewSettings, .relationSettings, .relationTargetChooser, .relationLimitChooser, .rollupSettings,
             .rollupCalculateMenu, .rollupNumberSettings, .relationProjectsTable, .relationPicker,
             .typeSelectPicker, .typeMultiSelectPicker, .typeStatusPicker, .typeOptionMenu, .typeDatePicker, .typeDateFormats,
             .typeFilesPopup, .typeSelectSettings, .typeStatusSettings, .typeNumberSettings, .typeChipsAndMeters: break
        default: break
        }
        await settle()
        return nil
    }

    static func tearDown(model: MainWindowModel) {
        menus?.close()
        menus = nil
        model.closeRowPeek()
        GalleryFormulasScene.tearDown()
        GalleryRelationsScene.tearDown()
        GalleryViewScene.tearDown()
        GalleryTypesScene.tearDown()
        GalleryRowTemplatesScene.tearDown(model: model)
        NSApp.windows.filter { $0.isVisible && $0.className.contains("PopupCardPanel") }.forEach { $0.orderOut(nil) }
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(400))
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews { if let match = find(type, in: subview) { return match } }
        return nil
    }
}
