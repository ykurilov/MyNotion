import AppKit
import Foundation
import Testing
@testable import Databases
@testable import DatabaseGrid
@testable import DatabaseViewBar
@testable import NotesCore

/// Окна вида без экрана (T082): страницы собирают строки по модели и пишут правки операциями.
@MainActor
@Suite("Окна вида: страницы")
struct ViewPanelsViewsTests {
    let t: PanelTestBase
    let controller: DatabaseTableController
    let panels: ViewPanels

    init() throws {
        t = try PanelTestBase()
        controller = try #require(DatabaseTableController(store: t.store, operations: t.operations, databaseId: t.base.databaseId, viewId: t.base.viewId))
        panels = ViewPanels(controller: controller)
    }

    func identifiers(_ view: NSView) -> [String] {
        var result: [String] = []
        func walk(_ view: NSView) {
            let id = view.accessibilityIdentifier()
            if !id.isEmpty { result.append(id) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return result
    }

    func find<T: NSView>(_ type: T.Type, _ id: String, in view: NSView) -> T? {
        if let view = view as? T, view.accessibilityIdentifier() == id { return view }
        for child in view.subviews { if let found = find(type, id, in: child) { return found } }
        return nil
    }

    @Test("Настройки длинной таблицы ограничены viewport, список свойств прокручивается в окне")
    func settingsUseVisibleTableArea() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        defer { panels.close(); window.orderOut(nil) }
        let root = try #require(window.contentView)
        let scroll = NSScrollView(frame: root.bounds.insetBy(dx: 40, dy: 30))
        scroll.autoresizingMask = [.width, .height]
        root.addSubview(scroll)
        let document = FlippedPanelDocument(frame: NSRect(x: 0, y: 0, width: 900, height: 276_000))
        scroll.documentView = document
        root.layoutSubtreeIfNeeded()
        panels.showViewSettings(in: document, selectName: false)
        let panel = try #require(find(ViewSettingsPanel.self, "view-settings-panel", in: root))
        let visible = document.convert(document.visibleRect, to: root).intersection(root.bounds)
        #expect(visible.height > 0 && visible.height <= 600)
        #expect(panel.superview === root)
        #expect(panel.frame.height == visible.height)
        #expect(panel.frame.maxX == visible.maxX)
        #expect(panel.frame.minY == visible.minY)
        panel.layoutSubtreeIfNeeded()
        try #require(find(PropertyPopupRow.self, "view-settings-group", in: panel)).press()
        panel.layoutSubtreeIfNeeded()
        let list = try #require(find(PanelPage.self, "grouping-window", in: panel))
        #expect(list.frame.height < visible.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200_000))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        let scrolled = document.convert(document.visibleRect, to: root).intersection(root.bounds)
        #expect(panel.frame.height == scrolled.height)
        #expect(panel.frame.minY == scrolled.minY)
        #expect(panel.frame.maxX == scrolled.maxX)
        window.setContentSize(NSSize(width: 700, height: 450))
        root.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        let resized = document.convert(document.visibleRect, to: root).intersection(root.bounds)
        #expect(panel.frame.height == resized.height)
        #expect(panel.frame.maxX == resized.maxX)
        scroll.documentView = nil
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(panel.superview == nil, "При уходе со страницы overlay должен закрываться")
        scroll.documentView = document
        panels.showViewSettings(in: document, selectName: false)
        #expect(find(ViewSettingsPanel.self, "view-settings-panel", in: root) != nil)
        panels.close()
        #expect(find(ViewSettingsPanel.self, "view-settings-panel", in: root) == nil)
        var owner: ViewPanels? = ViewPanels(controller: controller)
        weak var weakOwner = owner
        owner?.showViewSettings(in: document, selectName: false)
        #expect(find(ViewSettingsPanel.self, "view-settings-panel", in: root) != nil)
        owner = nil
        #expect(weakOwner == nil)
        #expect(find(ViewSettingsPanel.self, "view-settings-panel", in: root) == nil, "Освобождение presenter убирает overlay")
    }

    @Test("Простой фильтр выбора: условие, «•••», поиск и флажки вариантов; флажок пишет значение")
    func simpleFilterSelect() throws {
        let path = try t.operations.addFilter(for: t.select.id, to: t.base.viewId)
        let page = SimpleFilterPage(panels: panels, path: path)
        page.rebuild()
        let ids = identifiers(page)
        #expect(ids.contains("filter-operator"))
        #expect(ids.contains("filter-more"))
        #expect(ids.contains("filter-value-search"))
        #expect(ids.contains("filter-option-Средний"))
        try #require(find(ChoiceRowView.self, "filter-option-Средний", in: page)).press()
        let condition = try #require(try t.view().filterNode?.node(at: path)?.condition)
        #expect(FilterValues.selectedIds(condition.value) == [t.options[1].id])
    }

    @Test("Расширенный фильтр: строки правил, «+ Добавить правило», «Удалить фильтр»")
    func advanced() throws {
        let rule = try #require(AdvancedFilterModel.newRule(catalog: try t.catalog()))
        let (filter, path) = AdvancedFilterModel.addingAdvanced(rule, to: nil)
        try t.operations.setFilter(FilterEditing.addRule(FilterCondition(propertyId: t.check.id, op: .is, value: true), toGroup: path, in: filter), of: t.base.viewId)
        let page = AdvancedFilterPage(panels: panels, groupPath: path)
        page.rebuild()
        let ids = identifiers(page)
        #expect(ids.filter { $0 == "advanced-filter-property" }.count == 2)
        #expect(ids.contains("advanced-filter-joiner"))
        #expect(ids.contains("advanced-filter-add-1"))
        try #require(find(PropertyPopupRow.self, "advanced-filter-delete", in: page)).press()
        #expect(try t.view().filter == nil)
    }

    @Test("Видимость, группировка, раскладка: строки по модели, переключатели пишут вид")
    func otherPages() throws {
        let visibility = PropertyVisibilityPage(panels: panels)
        visibility.rebuild()
        #expect(identifiers(visibility).contains("visibility-hide-Часы"))
        #expect(!identifiers(visibility).contains("visibility-hide-Название"))
        try t.operations.group(by: t.select.id, in: t.base.viewId)
        controller.reload()
        let grouping = GroupingPage(panels: panels)
        grouping.rebuild()
        #expect(identifiers(grouping).contains("group-row-Высокий"))
        try #require(find(PanelToggleRow.self, "group-hide-empty", in: grouping)).press()
        #expect(try t.view().groupSettings?.hideEmpty == false)
        let layout = LayoutPage(panels: panels)
        layout.rebuild()
        #expect(!identifiers(layout).contains("layout-load-limit"))
        try #require(find(PanelToggleRow.self, "layout-wrap", in: layout)).press()
        #expect(try t.view().layout.wrapAllContent)
        let sorts = SortPage(panels: panels)
        try t.operations.sort(by: t.number.id, ascending: true, in: t.base.viewId)
        controller.reload()
        sorts.rebuild()
        #expect(identifiers(sorts).contains("sort-level-direction-0"))
    }
}

private final class FlippedPanelDocument: NSView {
    override var isFlipped: Bool { true }
}
