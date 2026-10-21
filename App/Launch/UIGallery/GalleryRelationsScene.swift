import AppKit
import DatabaseGrid
import DatabaseViewBar
import Databases
import NotesCore
import UIGallery

/// Связи и сводки в галерее (US4, T093) на эталоне «Задачи» ↔ «Проекты» (300 задач, 20 проектов): панель новой связи и
/// настроенной двусторонней, окна «Связана с» и «Лимит», окно ячейки связи, панель сводки и меню «Вычислить», таблица «Проекты» со
/// сводками и ответной связью. Сверка — `notion-relation-*.png`, `notion-rollup-*.png`.
@MainActor
enum GalleryRelationsScene {
    private static var menus: PropertyMenuPresenter?

    static func handles(_ kind: GalleryDatabases) -> Bool {
        [.relationNewSettings, .relationSettings, .relationTargetChooser, .relationLimitChooser, .rollupSettings, .rollupCalculateMenu,
         .relationProjectsTable, .relationPicker].contains(kind)
    }

    static func show(_ kind: GalleryDatabases, model: MainWindowModel, window: NSWindow) async -> String? {
        let store = model.store
        guard let sample = try? DatabaseSampleGenerator(taskCount: 300, projectCount: 20).ensure(in: store) else { return "эталона нет" }
        let onProjects = [.rollupSettings, .rollupCalculateMenu, .relationProjectsTable].contains(kind)
        model.library.reloadTree()
        model.select(onProjects ? sample.projectsId : sample.tasksId)
        await settle()
        guard let table = GalleryDatabasesScene.find(DatabaseTableView.self, in: window.contentView) else { return "таблица не показана" }
        let controller = table.controller
        let presenter = PropertyMenuPresenter(store: store, operations: model.databaseOperations, databaseId: controller.databaseId,
                                              viewId: controller.viewId)
        menus = presenter
        do {
            switch kind {
            case .relationNewSettings, .relationTargetChooser:
                let property = try model.databaseOperations.addProperty(to: sample.tasksId, name: "Связь", kind: .relation)
                await settle()
                presenter.showEditProperty(property.id, in: table)
                if kind == .relationTargetChooser { await press("relation-target", in: window) }
            case .relationSettings, .relationLimitChooser:
                presenter.showEditProperty(sample.taskProperties["Проект"]!, in: table)
                if kind == .relationLimitChooser { await press("relation-limit", in: window) }
            case .rollupSettings, .rollupCalculateMenu:
                presenter.showEditProperty(sample.projectProperties["Сумма часов"]!, in: table)
                if kind == .rollupCalculateMenu { await press("rollup-calculation", in: window) }
            case .relationPicker:
                // Окно ячейки связи первой задачи: выбранный проект с «−» и «Выбрать ещё».
                guard let column = controller.content.columns.firstIndex(where: { $0.property.id == sample.taskProperties["Проект"]! }) else {
                    return "нет колонки связи"
                }
                table.grid.select(CellPosition(row: 0, column: column))
                table.grid.beginEditing()
            default:
                window.makeFirstResponder(nil)
            }
        } catch {
            return "связь не записалась: \(error.localizedDescription)"
        }
        await settle()
        return nil
    }

    static func tearDown() {
        menus?.close()
        menus = nil
    }

    private static func settle() async { try? await Task.sleep(for: .milliseconds(400)) }

    /// Нажать строку окна по её имени доступности (строки окон рисуются сами).
    private static func press(_ identifier: String, in window: NSWindow) async {
        await settle()
        if let row = find(identifier, in: window.contentView) { _ = row.accessibilityPerformPress() }
    }

    private static func find(_ identifier: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == identifier { return view }
        for subview in view.subviews { if let match = find(identifier, in: subview) { return match } }
        return nil
    }
}
