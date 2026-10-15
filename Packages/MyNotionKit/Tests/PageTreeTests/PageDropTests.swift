import Foundation
import NotesCore
import Testing
@testable import PageTree

@Suite("Сброс страницы при перетаскивании в дереве")
struct PageDropTests {
    // Корень: Проекты (Приложение (Заметки), Сайт), Архив.
    let projects = Self.page("Проекты", key: "1")
    let archive = Self.page("Архив", key: "2")
    let app: Page
    let site: Page
    let notes: Page
    let tree: PageTreeSnapshot

    init() {
        app = Self.page("Приложение", key: "1", parent: projects.id)
        site = Self.page("Сайт", key: "2", parent: projects.id)
        notes = Self.page("Заметки", key: "1", parent: app.id)
        tree = PageTreeSnapshot(allPages: [projects, archive, app, site, notes])
    }

    private static func page(_ title: String, key: String, parent: UUID? = nil) -> Page {
        Page(title: title, parentId: parent, sortKey: FractionalSortKey(rawValue: key)!, createdAt: .now, updatedAt: .now)
    }

    @Test("На страницу — внутрь, в конец её подстраниц")
    func dropOnPageGoesInside() {
        let drop = PageDrop.resolve(dragged: site.id, onto: archive.id, childIndex: PageDrop.onItem, in: tree)
        #expect(drop == PageDrop(parentId: archive.id, index: 0))

        let intoProjects = PageDrop.resolve(dragged: archive.id, onto: projects.id, childIndex: PageDrop.onItem, in: tree)
        #expect(intoProjects == PageDrop(parentId: projects.id, index: 2))
    }

    @Test("Между страницами — рядом, на указанное место")
    func dropBetweenGoesBeside() {
        let drop = PageDrop.resolve(dragged: archive.id, onto: projects.id, childIndex: 1, in: tree)
        #expect(drop == PageDrop(parentId: projects.id, index: 1))
    }

    @Test("Перестановка среди тех же соседей вниз учитывает, что страница уходит со своего места")
    func dropLowerAmongSameSiblings() {
        // Проекты на место после Архива: дерево предлагает индекс 2, без самой страницы это 1.
        let drop = PageDrop.resolve(dragged: projects.id, onto: nil, childIndex: 2, in: tree)
        #expect(drop == PageDrop(parentId: nil, index: 1))

        let up = PageDrop.resolve(dragged: archive.id, onto: nil, childIndex: 0, in: tree)
        #expect(up == PageDrop(parentId: nil, index: 0))
    }

    @Test("Сброс в себя или своего потомка запрещён")
    func dropIntoOwnBranchIsRejected() {
        #expect(PageDrop.resolve(dragged: projects.id, onto: notes.id, childIndex: PageDrop.onItem, in: tree) == nil)
        #expect(PageDrop.resolve(dragged: projects.id, onto: app.id, childIndex: 0, in: tree) == nil)
        #expect(PageDrop.resolve(dragged: app.id, onto: app.id, childIndex: PageDrop.onItem, in: tree) == nil)
    }

    @Test("Сброс на пустое место панели — в конец корня")
    func dropOnEmptySpaceGoesToRootEnd() {
        let drop = PageDrop.resolve(dragged: notes.id, onto: nil, childIndex: PageDrop.onItem, in: tree)
        #expect(drop == PageDrop(parentId: nil, index: 2))
    }
}
