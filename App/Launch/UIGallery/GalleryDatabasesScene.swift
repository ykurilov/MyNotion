import AppKit
import DatabaseGrid
import Databases
import NotesCore
import UIGallery
import VisualStyle

/// Базы в галерее (этап 0, T029): сетка вида поверх окна — пустая новая база и таблица эталона (уменьшенного:
/// 300 задач). Страницу базы на всё окно делает US1 — тогда сцена откроет её обычным переходом.
@MainActor
enum GalleryDatabasesScene {
    private static var overlay: NSView?

    static func show(_ kind: GalleryDatabases, model: MainWindowModel, window: NSWindow) async -> String? {
        let store = model.store
        let viewId: UUID
        let title: String
        do {
            switch kind {
            case .empty:
                let created = try DatabaseOperations(store: store).createDatabase(in: nil, isInline: false)
                viewId = created.viewId
                title = ""
            case .sampleTable:
                let sample = try DatabaseSampleGenerator(taskCount: 300, projectCount: 20).ensure(in: store)
                viewId = sample.tableViewId
                title = DatabaseSampleGenerator.tasksTitle
            }
        } catch {
            return "база не записалась: \(error.localizedDescription)"
        }
        guard let opened = try? ViewQuery.open(viewId, in: store), let content = window.contentView else { return "вид базы не открылся" }
        let columns = ViewQuery.visiblePropertyIds(of: opened.view, catalog: opened.catalog).compactMap { id -> GridColumn? in
            guard let property = opened.catalog.propertiesById[id] else { return nil }
            let width = (opened.view.columns.array ?? []).first { $0["propertyId"]?.string == id.uuidString.lowercased() }?["width"]?.number
            return GridColumn(property: property, width: CGFloat(width ?? (property.kind == .title ? 280 : 200)))
        }
        let grid = DatabaseGridView(content: GridContent(store: store, catalog: opened.catalog, columns: columns, rowIds: opened.result.rowIds))
        let host = GalleryOverlayView(frame: content.bounds)
        host.autoresizingMask = [.width, .height]
        let heading = NSTextField(labelWithString: title.isEmpty ? "Новая база" : title)
        heading.font = .systemFont(ofSize: 32, weight: .bold)
        heading.textColor = title.isEmpty ? Palette.textSecondary : Palette.textPrimary
        heading.frame = NSRect(x: 96, y: 72, width: content.bounds.width - 192, height: 44)
        heading.autoresizingMask = [.width]
        grid.frame = NSRect(x: 96, y: 140, width: content.bounds.width - 192, height: content.bounds.height - 180)
        grid.autoresizingMask = [.width, .height]
        host.addSubview(heading)
        host.addSubview(grid)
        content.addSubview(host)
        overlay = host
        try? await Task.sleep(for: .milliseconds(400))
        return nil
    }

    static func tearDown() {
        overlay?.removeFromSuperview()
        overlay = nil
    }
}

/// Подложка сцены цвета страницы: снимок — только база.
private final class GalleryOverlayView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Palette.pageBackground.setFill()
        dirtyRect.fill()
    }
}
