import AppKit
import DatabaseGrid
import DatabaseViewBar
import Databases
import NotesCore
import UIGallery

/// Шаблоны строк в галерее (US6, T099): «Создать ▾» новой базы без шаблонов и «Задач» с «Багом» по умолчанию и «Созвоном»,
/// меню «•••» шаблона, правка шаблона по центру с янтарной полосой, «Быстрый выбор» окна даты шаблона.
/// Сверка — `notion-new-dropdown-templates*.png`, `notion-template-item-menu.png`, `notion-template-editor.png`,
/// `notion-template-date-shortcuts-picker.png`.
@MainActor
enum GalleryRowTemplatesScene {
    static func handles(_ kind: GalleryDatabases) -> Bool {
        [.rowTemplatesMenuEmpty, .rowTemplatesMenu, .rowTemplateItemMenu, .rowTemplateEditor, .rowTemplateDateShortcuts].contains(kind)
    }

    static func show(_ kind: GalleryDatabases, model: MainWindowModel, window: NSWindow) async -> String? {
        let store = model.store
        do {
            let databaseId: UUID
            var templates: [UUID] = []
            if kind == .rowTemplatesMenuEmpty {
                databaseId = try DatabaseOperations(store: store).createDatabase(in: nil, isInline: false).databaseId
            } else {
                let sample = try DatabaseSampleGenerator(taskCount: 300, projectCount: 20).ensure(in: store)
                databaseId = sample.tasksId
                templates = try ensureTemplates(in: sample, model: model)
            }
            model.library.reloadTree()
            model.select(databaseId)
            await settle()
            switch kind {
            case .rowTemplatesMenuEmpty, .rowTemplatesMenu:
                await press("database-new-row-templates", in: window)
            case .rowTemplateItemMenu:
                await press("database-new-row-templates", in: window)
                await press("row-template-\(templates[0])-more", in: window)
            case .rowTemplateEditor, .rowTemplateDateShortcuts:
                model.openRow(templates[0], mode: .centerPeek)
                await settle()
                window.makeFirstResponder(nil)
                if kind == .rowTemplateDateShortcuts {
                    guard let anchor = find(in: window.contentView, where: { $0.accessibilityIdentifier() == "row-property" && $0.accessibilityLabel() == "Срок" }),
                          let propertyId = try propertyId("Срок", of: databaseId, store: store) else { return "у шаблона нет «Срока»" }
                    anchor.scrollToVisible(anchor.bounds)
                    await settle()
                    RowValuePopup.show(rowId: templates[0], propertyId: propertyId, store: store, operations: model.databaseOperations, below: anchor)
                }
            default:
                break
            }
        } catch {
            return "шаблоны не записались: \(error.localizedDescription)"
        }
        await settle()
        return nil
    }

    static func tearDown(model: MainWindowModel) {
        RowValuePopup.close()
        model.closeRowPeek()
    }

    /// «Баг» (🐞, «Срок» — «Сегодня», чек-лист в теле) по умолчанию и «Созвон» (📞); один раз на базу галереи.
    private static func ensureTemplates(in sample: DatabaseSampleGenerator.Sample, model: MainWindowModel) throws -> [UUID] {
        let store = model.store
        let existing = try RowTemplates.list(of: sample.tasksId, in: store).templates.map(\.id)
        if !existing.isEmpty { return existing }
        let operations = model.databaseOperations
        let bug = try operations.addRowTemplate(to: sample.tasksId, title: "Баг")
        let call = try operations.addRowTemplate(to: sample.tasksId, title: "Созвон")
        try store.write { tx throws in
            for (id, icon) in [(bug, "🐞"), (call, "📞")] {
                guard var page = try tx.page(id) else { continue }
                page.icon = icon
                try tx.updatePage(page)
            }
            if var first = try tx.blocks(ofPage: bug).first {
                first.kind = .checkbox
                first.text = InlineText("Воспроизвести на чистой базе")
                _ = try tx.updateBlock(first)
            }
        }
        if let deadline = try propertyId("Срок", of: sample.tasksId, store: store) {
            let now = DateParts(Date(), calendar: .current)
            var value = DateCellValue(day: now, timeZone: TimeZone.current.identifier)
            value.templateRelative = "today"
            try operations.setCell(rowId: bug, propertyId: deadline, value: value.json)
        }
        try operations.setDefaultRowTemplate(bug, of: sample.tasksId)
        return [bug, call]
    }

    private static func propertyId(_ name: String, of databaseId: UUID, store: NotesStore) throws -> UUID? {
        try DatabaseCatalog.read(databaseId, in: store).propertiesById.values.first { $0.name == name }?.id
    }

    private static func settle() async { try? await Task.sleep(for: .milliseconds(400)) }

    /// Нажать вид окна или карточки по имени доступности (кнопки и строки меню рисуются сами).
    private static func press(_ identifier: String, in window: NSWindow) async {
        await settle()
        let roots = [window.contentView] + (window.childWindows ?? []).map(\.contentView)
        for root in roots {
            if let view = find(in: root, where: { $0.accessibilityIdentifier() == identifier }) {
                _ = view.accessibilityPerformPress()
                return
            }
        }
    }

    private static func find(in view: NSView?, where matches: (NSView) -> Bool) -> NSView? {
        guard let view else { return nil }
        if matches(view) { return view }
        for subview in view.subviews { if let match = find(in: subview, where: matches) { return match } }
        return nil
    }
}
