import NotesCore
import Testing
import UIGallery

@Suite("Список состояний галереи интерфейса")
struct GalleryCatalogTests {
    let states = GalleryCatalog.states
    var scenes: Set<GalleryScene> { Set(states.map(\.scene)) }

    @Test("Имена состояний и файлов уникальны")
    func namesAreUnique() {
        let ids = states.map(\.id)
        #expect(Set(ids).count == ids.count)
        let files = GalleryCatalog.shots.map(\.fileName)
        #expect(Set(files).count == files.count)
        #expect(Set(states.map(\.scene)).count == states.count)
    }

    @Test("Каждое состояние — в светлой и тёмной теме, в окне 1440×900")
    func everyStateInBothThemes() {
        for state in states {
            #expect(state.sizes.contains(.wide), "\(state.id)")
            for size in state.sizes {
                let themes = GalleryCatalog.shots.filter { $0.state == state && $0.size == size }.map(\.theme)
                #expect(themes == [.light, .dark], "\(state.id) \(size.name)")
            }
        }
    }

    @Test("Страница: образец сверху и снизу, пустая страница, пустое название, вложенные списки, путь, полоса ошибки")
    func pageStatesPresent() {
        let required: [GalleryScene] = [
            .samplePage(scrolledToBottom: false), .samplePage(scrolledToBottom: true), .emptyPage, .untitledPage,
            .nestedLists, .longBreadcrumb, .saveErrorBanner,
        ]
        for scene in required { #expect(scenes.contains(scene), "\(scene)") }
    }

    @Test("Каждый тип блока: с текстом, пустой в середине и в конце, с курсором и без")
    func everyBlockKindPresent() {
        for kind in BlockKind.allCases where kind != .pageLink {
            for caret in GalleryCaret.allCases {
                #expect(scenes.contains(.block(kind, caret)), "\(kind) \(caret)")
            }
        }
    }

    @Test("Правка: ручки у абзаца, заголовка 1, пункта и чекбокса, меню «/» с фильтром и без, меню блока, выделение текста и блоков, панель форматирования, переносы строк")
    func editingStatesPresent() {
        let required: [GalleryScene] = [
            .blockHover(.paragraph), .blockHover(.heading1), .blockHover(.bulletItem), .blockHover(.checkbox),
            .slashMenu(filter: ""), .blockMenu, .formattedSelection, .selectionAcrossBlocks, .blockSelection, .softLineBreaks, .selectionAcrossSoftBreaks,
            .formatBar(kindMenu: false), .formatBar(kindMenu: true),
        ]
        for scene in required { #expect(scenes.contains(scene), "\(scene)") }
        #expect(scenes.contains { if case .slashMenu(let filter) = $0 { !filter.isEmpty } else { false } })
    }

    @Test("Иконка страницы: «Добавить иконку» под мышью, окно эмодзи, поиск в нём")
    func pageIconStatesPresent() {
        for state in GalleryPageIcon.allCases { #expect(scenes.contains(.pageIcon(state)), "\(state)") }
    }

    @Test("Боковая панель и корзина")
    func sidebarAndTrashStatesPresent() {
        let required: [GalleryScene] = [
            .sidebarTree(collapsed: false), .sidebarTree(collapsed: true), .sidebarRowHover(longTitle: false),
            .sidebarRowHover(longTitle: true), .sidebarSelectedRow, .sidebarRenaming, .sidebarHidden,
        ] + GalleryTrash.allCases.map(GalleryScene.trash)
        for scene in required { #expect(scenes.contains(scene), "\(scene)") }
    }

    @Test("Пустая корзина снимается после всех остальных состояний корзины")
    func emptyTrashIsLast() throws {
        let trash = states.filter { if case .trash = $0.scene { true } else { false } }
        #expect(trash.last?.scene == .trash(.openEmpty))
    }

    @Test("Ключевые состояния — ещё и в узком окне 900×700")
    func keyStatesInNarrowWindow() {
        let narrow = Set(states.filter { $0.sizes.contains(.narrow) }.map(\.scene))
        let required: [GalleryScene] = [
            .samplePage(scrolledToBottom: false), .emptyPage, .longBreadcrumb, .saveErrorBanner, .blockHover(.paragraph),
            .slashMenu(filter: ""), .sidebarTree(collapsed: false), .sidebarRowHover(longTitle: true),
            .trash(.rowAtBottom), .trash(.open),
        ]
        for scene in required { #expect(narrow.contains(scene), "\(scene)") }
    }
}
