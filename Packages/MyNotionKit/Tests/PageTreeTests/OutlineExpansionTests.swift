import AppKit
import NotesCore
import Testing
@testable import PageTree

/// Раскрытие веток дерева (сценарий 2.1 spec.md): всё, что не свёрнуто, видно на любой глубине —
/// новая подстраница подстраницы появляется в дереве, а свёрнутая ветка остаётся свёрнутой.
@MainActor
@Suite("Раскрытие веток дерева")
struct OutlineExpansionTests {
    let projects = Self.page("Проекты", key: "a")
    let app: Page
    let notes: Page

    init() {
        app = Self.page("MyNotion", parent: projects.id, key: "a")
        notes = Self.page("Заметки", parent: app.id, key: "a")
    }

    @Test("Подстраница подстраницы видна: не свёрнутые ветки раскрыты на любой глубине")
    func openBranchesAreExpandedAtEveryLevel() {
        let (outline, dataSource) = Self.outline()
        // Как ⌘N «Проекты», ⇧⌘N «MyNotion», ⇧⌘N «Заметки»: у «MyNotion» дети появляются, когда «Проекты» уже раскрыты.
        dataSource.show(PageTreeSnapshot(allPages: [projects]), collapsedPageIds: [], selectedPageId: projects.id)
        dataSource.show(PageTreeSnapshot(allPages: [projects, app]), collapsedPageIds: [], selectedPageId: app.id)
        dataSource.show(PageTreeSnapshot(allPages: [projects, app, notes]), collapsedPageIds: [], selectedPageId: notes.id)
        #expect(Self.titles(outline) == ["Проекты", "MyNotion", "Заметки"])
        #expect(outline.selectedRow == 2, "Новая подстраница выбрана")
    }

    @Test("Свёрнутая вложенная ветка остаётся свёрнутой")
    func collapsedNestedBranchStaysCollapsed() {
        let (outline, dataSource) = Self.outline()
        dataSource.show(PageTreeSnapshot(allPages: [projects, app, notes]), collapsedPageIds: [app.id], selectedPageId: nil)
        #expect(Self.titles(outline) == ["Проекты", "MyNotion"])
    }

    @Test("← сворачивает выбранную ветку, → разворачивает")
    func arrowKeysCollapseAndExpand() throws {
        let (outline, dataSource) = Self.outline()
        dataSource.show(PageTreeSnapshot(allPages: [projects, app, notes]), collapsedPageIds: [], selectedPageId: app.id)
        outline.keyDown(with: try Self.arrow(NSLeftArrowFunctionKey, keyCode: 123))
        #expect(Self.titles(outline) == ["Проекты", "MyNotion"])
        #expect(dataSource.collapsedPageIds == [app.id])
        outline.keyDown(with: try Self.arrow(NSRightArrowFunctionKey, keyCode: 124))
        #expect(Self.titles(outline) == ["Проекты", "MyNotion", "Заметки"])
    }

    private static func arrow(_ key: Int, keyCode: UInt16) throws -> NSEvent {
        let characters = String(Character(UnicodeScalar(UInt16(key))!))
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
                                             windowNumber: 0, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private static func page(_ title: String, parent: UUID? = nil, key: String) -> Page {
        Page(title: title, parentId: parent, sortKey: FractionalSortKey(rawValue: key)!, createdAt: .now, updatedAt: .now)
    }

    private static func titles(_ outline: NSOutlineView) -> [String] {
        (0..<outline.numberOfRows).compactMap { row in
            (outline.item(atRow: row) as? PageOutlineItem).flatMap { item in
                (outline.dataSource as? PageOutlineDataSource)?.tree.page(item.pageId)?.title
            }
        }
    }

    private static func outline() -> (PageOutlineView, PageOutlineDataSource) {
        let outline = PageOutlineView(frame: NSRect(x: 0, y: 0, width: 250, height: 300))
        let dataSource = PageOutlineDataSource(actions: PageTreeActions(select: { _ in }, rename: { _, _ in }, move: { _, _, _ in },
                                                                        moveToTrash: { _ in }, addSubpage: { _ in },
                                                                        collapsedPagesChanged: { _ in }))
        dataSource.attach(to: outline)
        retained.append(dataSource)
        return (outline, dataSource)
    }

    /// Источник данных дерева держится слабо: живёт до конца прогона.
    private static var retained: [AnyObject] = []
}
