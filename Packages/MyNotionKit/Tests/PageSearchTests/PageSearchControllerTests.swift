import AppKit
import Testing
@testable import NotesCore
@testable import PageSearch

/// Клавиши поля поиска. Окно невидимо: выдача на экран не выходит, но выбор и открытие работают так же.
@Suite("Поле поиска: ввод, ↑↓, Enter, Esc")
@MainActor
struct PageSearchControllerTests {
    let library: SearchLibrary
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    let field = SearchFieldView(frame: NSRect(x: 10, y: 150, width: 250, height: 30))

    init() throws {
        library = try SearchLibrary()
        window.contentView?.addSubview(field)
    }

    private func controller(opening opened: @escaping (UUID) -> Void = { _ in }) -> PageSearchController {
        let store = library.store
        let controller = PageSearchController(store: store, tree: { PageTreeSnapshot(allPages: (try? store.pageOutline()) ?? []) },
                                              open: opened)
        field.textField.delegate = controller
        controller.fieldView = field
        return controller
    }

    private func press(_ selector: Selector, in controller: PageSearchController) -> Bool {
        let editor = field.textField.currentEditor() as? NSTextView ?? NSTextView()
        return controller.control(field.textField, textView: editor, doCommandBy: selector)
    }

    @Test("Ввод показывает выдачу, первая строка выбрана; ↓ и ↑ двигают выбор в пределах выдачи")
    func arrowsMoveSelection() throws {
        try library.page("Кот")
        try library.page("Котлеты")
        let controller = controller()

        controller.type("кот")
        #expect(controller.results.count == 2)
        #expect(controller.selectedIndex == 0)

        #expect(press(#selector(NSResponder.moveDown(_:)), in: controller))
        #expect(controller.selectedIndex == 1)
        _ = press(#selector(NSResponder.moveDown(_:)), in: controller)
        #expect(controller.selectedIndex == 1)
        _ = press(#selector(NSResponder.moveUp(_:)), in: controller)
        _ = press(#selector(NSResponder.moveUp(_:)), in: controller)
        #expect(controller.selectedIndex == 0)
    }

    @Test("Enter открывает выбранную страницу и очищает поле")
    func enterOpensSelectedPage() throws {
        try library.page("Кот")
        try library.page("Котлеты")
        var opened: [UUID] = []
        let controller = controller { opened.append($0) }

        controller.type("кот")
        let second = try #require(controller.results.last)
        _ = press(#selector(NSResponder.moveDown(_:)), in: controller)
        #expect(press(#selector(NSResponder.insertNewline(_:)), in: controller))

        #expect(opened == [second.pageId])
        #expect(controller.query.isEmpty)
        #expect(controller.results.isEmpty)
    }

    @Test("Esc закрывает выдачу и очищает поле, ничего не открывая")
    func escapeDismisses() throws {
        try library.page("Кот")
        var opened: [UUID] = []
        let controller = controller { opened.append($0) }

        controller.type("кот")
        #expect(press(#selector(NSResponder.cancelOperation(_:)), in: controller))

        #expect(opened.isEmpty)
        #expect(controller.query.isEmpty)
        #expect(!controller.isShowingResults)
    }

    @Test("Ничего не нашлось: Enter ничего не открывает; остальные клавиши поле обрабатывает само")
    func emptyResults() throws {
        var opened: [UUID] = []
        let controller = controller { opened.append($0) }

        controller.type("несуществующее")
        #expect(controller.results.isEmpty)
        _ = press(#selector(NSResponder.insertNewline(_:)), in: controller)
        #expect(opened.isEmpty)
        #expect(!press(#selector(NSResponder.moveLeft(_:)), in: controller))
    }

    @Test("Выдача не выходит на экран, пока окно не видно")
    func noPopupWithoutVisibleWindow() throws {
        try library.page("Кот")
        let controller = controller()

        controller.type("кот")
        #expect(!controller.isShowingResults)
        #expect(NSApp.windows.allSatisfy { $0.accessibilityIdentifier() != "search-results" || !$0.isVisible })
    }
}
