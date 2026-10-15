import AppKit
import NotesCore
import Testing
@testable import PageTree

/// Вход в окно выбора иконки из боковой панели (FR-034): щелчок по иконке строки — то же окно, что в шапке страницы.
/// Дерево только сообщает, где иконка; окно открывает приложение.
@MainActor
@Suite("Иконка строки дерева")
struct SidebarIconEntryTests {
    @Test("Щелчок по иконке строки сообщает страницу и место иконки")
    func clickOnIconChoosesIcon() throws {
        let page = Self.page
        var chosen: [(UUID, NSView)] = []
        let actions = PageTreeActions(select: { _ in }, rename: { _, _ in }, move: { _, _, _ in }, moveToTrash: { _ in },
                                      addSubpage: { _ in }, collapsedPagesChanged: { _ in },
                                      chooseIcon: { chosen.append(($0, $1)) })
        let outline = PageOutlineView(frame: NSRect(x: 0, y: 0, width: 250, height: 300))
        let dataSource = PageOutlineDataSource(actions: actions)
        dataSource.attach(to: outline)
        dataSource.show(PageTreeSnapshot(allPages: [page]), collapsedPageIds: [], selectedPageId: page.id)
        let cell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? PageTreeCellView)
        cell.layoutSubtreeIfNeeded()

        #expect(!cell.iconButton.isHidden)
        #expect(cell.iconButton.frame == cell.documentIcon.frame, "Кнопка не на месте иконки")
        // Строка не в окне: нажатие — отправкой действия кнопки её цели.
        let button = cell.iconButton
        #expect(NSApplication.shared.sendAction(try #require(button.action), to: button.target, from: button))
        #expect(chosen.map(\.0) == [page.id])
        #expect(chosen.first?.1 === cell.iconButton)
        withExtendedLifetime(dataSource) {}
    }

    @Test("Пока вместо иконки стрелка ветки, щелчок по ней сворачивает ветку, а не открывает окно")
    func disclosureHidesIconButton() {
        let cell = PageTreeCellView(frame: NSRect(x: 0, y: 0, width: 250, height: 30))
        let page = Self.page
        cell.show(Self.page, title: Self.page.title, hasChildren: true, isExpanded: true)
        #expect(!cell.iconButton.isHidden)
        cell.isRowHovered = true
        #expect(cell.iconButton.isHidden)
    }

    private static let page = Page(title: "Проекты", icon: "📘", sortKey: FractionalSortKey(rawValue: "a")!, createdAt: .now, updatedAt: .now)
}
