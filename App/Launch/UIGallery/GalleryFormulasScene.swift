import AppKit
import DatabaseGrid
import Databases
import Formulas
import NotesCore
import UIGallery
import VisualStyle

/// Формулы в галерее (US5, T055): редактор «Изменить формулу» в четырёх состояниях поверх страницы и ячейки формул всех
/// типов итога в сетке эталона «Задачи» (300 строк). Сверка — `notion-formula-editor*.png`.
@MainActor
enum GalleryFormulasScene {
    private static var overlay: NSView?

    static func handles(_ kind: GalleryDatabases) -> Bool {
        [.formulaEditorEmpty, .formulaEditorResult, .formulaEditorError, .formulaEditorCycle, .formulaCells].contains(kind)
    }

    /// Сцена формул; итог — текст сбоя или `nil`.
    static func show(_ kind: GalleryDatabases, model: MainWindowModel, window: NSWindow) async -> String? {
        guard let content = window.contentView else { return "окна нет" }
        let store = model.store
        do {
            let sample = try DatabaseSampleGenerator(taskCount: 300, projectCount: 20).ensure(in: store)
            let host = GalleryOverlayView(frame: content.bounds)
            host.autoresizingMask = [.width, .height]
            content.addSubview(host)
            overlay = host
            if kind == .formulaCells {
                try showCells(sample: sample, store: store, in: host)
            } else {
                try showEditor(kind, sample: sample, store: store, in: host, window: window)
            }
        } catch {
            return "формулы не открылись: \(error)"
        }
        try? await Task.sleep(for: .milliseconds(500))
        return nil
    }

    static func tearDown() {
        overlay?.removeFromSuperview()
        overlay = nil
    }

    private static func showEditor(_ kind: GalleryDatabases, sample: DatabaseSampleGenerator.Sample, store: NotesStore, in host: NSView,
                                   window: NSWindow) throws {
        let operations = DatabaseOperations(store: store)
        let rows = try ViewQuery.open(sample.tableViewId, in: store)?.result.rowIds ?? []
        let property: DatabaseProperty
        var text = ""
        switch kind {
        case .formulaEditorCycle:
            // «Сумма» = prop("Итог"); правим «Итог» на prop("Сумма") — круг.
            let sum = try operations.addProperty(to: sample.tasksId, name: "Сумма", kind: .formula)
            try operations.setFormula(sum.id, display: #"prop("Итог")"#)
            property = try store.write { tx in try tx.property(sample.taskProperties["Итог"]!)! }
            text = #"prop("Сумма") + "!""#
        default:
            property = try operations.addProperty(to: sample.tasksId, name: "Формула", kind: .formula)
            text = switch kind {
            case .formulaEditorResult: #""Привет, " + prop("Название")"#
            case .formulaEditorError: #"dateBetween("2026-10-21", now(), "days")"#
            default: ""
            }
        }
        let editorModel = try FormulaEditorModel(store: store, property: property, rows: rows)
        let editor = FormulaEditorView(model: editorModel, operations: operations)
        let card = GalleryCardView(frame: NSRect(x: (host.bounds.width - FormulaEditorView.size.width) / 2 - 12, y: 150,
                                                 width: FormulaEditorView.size.width + 24, height: FormulaEditorView.size.height + 24))
        editor.frame.origin = NSPoint(x: 12, y: 12)
        card.addSubview(editor)
        let heading = NSTextField(labelWithString: DatabaseSampleGenerator.tasksTitle)
        heading.font = .systemFont(ofSize: 32, weight: .bold)
        heading.textColor = Palette.textPrimary
        heading.frame = NSRect(x: 96, y: 72, width: 600, height: 44)
        host.addSubview(heading)
        host.addSubview(card)
        editor.focusField()
        if !text.isEmpty { editor.type(text) }
    }

    private static func showCells(sample: DatabaseSampleGenerator.Sample, store: NotesStore, in host: NSView) throws {
        let operations = DatabaseOperations(store: store)
        let formulas: [(String, String, JSONValue)] = [
            ("Часы × 2", #"prop("Часы") * 2"#, ["numberFormat": ["format": "number", "decimals": 1]]),
            ("Метка", #"if(prop("Сделано"), "✅ готово", "⏳ в работе")"#, .emptyObject),
            ("Важно и не сделано", #"prop("Важно") and not prop("Сделано")"#, .emptyObject),
            ("Срок + неделя", #"dateAdd(prop("Срок"), 1, "weeks")"#, ["dateFormat": "full"]),
            ("Теги списком", #"prop("Теги")"#, .emptyObject),
            ("Проекты", #"prop("Проект")"#, .emptyObject),
        ]
        var ids: [UUID] = []
        for (name, text, config) in formulas {
            let property = try operations.addProperty(to: sample.tasksId, name: name, kind: .formula, config: config)
            try operations.setFormula(property.id, display: text)
            ids.append(property.id)
        }
        _ = try FormulaRecompute(store: store, databaseId: sample.tasksId).recomputeAll()
        guard let opened = try ViewQuery.open(sample.tableViewId, in: store) else { return }
        let columns = ([opened.catalog.titleProperty?.id].compactMap { $0 } + ids).compactMap { id -> GridColumn? in
            opened.catalog.propertiesById[id].map { GridColumn(property: $0, width: $0.kind == .title ? 240 : 190) }
        }
        let grid = DatabaseGridView(content: GridContent(store: store, catalog: opened.catalog, columns: columns, rowIds: opened.result.rowIds))
        let heading = NSTextField(labelWithString: DatabaseSampleGenerator.tasksTitle)
        heading.font = .systemFont(ofSize: 32, weight: .bold)
        heading.textColor = Palette.textPrimary
        heading.frame = NSRect(x: 96, y: 72, width: 600, height: 44)
        grid.frame = NSRect(x: 96, y: 140, width: host.bounds.width - 192, height: host.bounds.height - 180)
        grid.autoresizingMask = [.width, .height]
        host.addSubview(heading)
        host.addSubview(grid)
    }
}

/// Карточка с тенью всплывающего окна вокруг редактора.
private final class GalleryCardView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        PopupSurface.draw(card: bounds.insetBy(dx: 10, dy: 10), shadow: Palette.popupCardShadow)
    }
}
