import AppKit
import NotesCore
import Testing
import VisualStyle
@testable import PageEditor

/// Правая кнопка по блоку-ссылке на страницу: меню страницы, как у Notion, вместо системного меню текста.
@MainActor
@Suite("Меню ссылки на страницу по правой кнопке")
struct PageLinkContextMenuTests {
    let target = UUID()

    private func editor() throws -> EditorFixture {
        let editor = try EditorFixture([.paragraph("Текст"), EditorFixture.Spec(kind: .pageLink, link: target)])
        editor.textView.layoutSubtreeIfNeeded()
        return editor
    }

    private func rightClick(_ editor: EditorFixture, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: editor.textView.convert(point, to: nil),
                                        modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber,
                                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    private func linkPoint(_ editor: EditorFixture) throws -> NSPoint {
        let view = editor.textView
        let line = try #require(view.markerLine(ofBlockAt: 1))
        let origin = view.textContainerOrigin
        return NSPoint(x: origin.x + view.textContainer!.size.width - 20, y: origin.y + line.top + line.height / 2)
    }

    private func textPoint(_ editor: EditorFixture) throws -> NSPoint {
        let view = editor.textView
        let line = try #require(view.markerLine(ofBlockAt: 0))
        let origin = view.textContainerOrigin
        return NSPoint(x: origin.x + 10, y: origin.y + line.top + line.height / 2)
    }

    @Test("Правая кнопка по ссылке: вместо системного меню — меню страницы по ссылке, а не текущей")
    func rightClickOnLinkOpensPageMenu() throws {
        let editor = try editor()
        let view = editor.textView
        var requests: [PageLinkMenuRequest] = []
        view.pageLinkMenuEntries = { request in
            requests.append(request)
            return [.action(ActionMenuAction(title: "Дублировать", icon: nil) { _ in })]
        }
        let menu = view.menu(for: try rightClick(editor, at: try linkPoint(editor)))
        #expect(menu == nil, "системного меню текста нет")
        #expect(requests.map(\.pageId) == [target])
        #expect(requests.first?.pageId != editor.pageId)
        #expect(requests.first?.blockId == editor.document.blocks[1].id)
        #expect(view.pageLinkMenu.menu?.outline == ["Преобразовать в", "Цвет", "—", "Дублировать"])
        view.pageLinkMenu.close()
    }

    @Test("«Преобразовать в» и «Цвет» — подменю, как в меню блока")
    func blockSubmenus() throws {
        let editor = try editor()
        let menu = editor.textView.pageLinkMenuView(forBlock: editor.document.blocks[1].id, pageId: target, anchor: .zero)
        let rows = menu.rowViews.prefix(2)
        #expect(rows.map(\.action.title) == [PopupMenuItem.turnInto.title, PopupMenuItem.color.title])
        #expect(rows.map(\.action.opensSubmenu) == [true, true])
    }

    @Test("Правая кнопка по обычному тексту — прежнее системное меню")
    func rightClickOnTextKeepsSystemMenu() throws {
        let editor = try editor()
        let view = editor.textView
        var called = false
        view.pageLinkMenuEntries = { _ in
            called = true
            return []
        }
        let menu = view.menu(for: try rightClick(editor, at: try textPoint(editor)))
        #expect(menu != nil)
        #expect(!called)
        #expect(view.pageLinkMenu.menu == nil)
    }
}
