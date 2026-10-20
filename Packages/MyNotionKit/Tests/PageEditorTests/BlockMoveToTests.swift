import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// «Переместить в» блоков (US4, research R8): пункт меню «⋮⋮» с ⇧⌘P и клавиша при выделенных блоках просят окно
/// открыть «Переместить в…» для этих блоков (`onSubpageRequest`). Без выделенных блоков ⇧⌘P — не редактора: страницу
/// переносит меню окна.
@MainActor
@Suite("Переместить блоки в")
struct BlockMoveToTests {
    private func keyEvent(_ editor: EditorFixture, _ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                      windowNumber: editor.window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    @Test("Меню блока: «Переместить в» ⇧⌘P сразу за «Дублировать»; у подстраницы — тоже, начинает группу")
    func menuHasMoveTo() {
        let paragraph = PopupMenuItem.blockMenuItems(for: .paragraph)
        #expect(paragraph.map(\.title) == ["Преобразовать в", "Цвет", "Дублировать", "Переместить в", "Удалить"])
        #expect(paragraph.map(\.hint) == [nil, nil, "⌘D", "⌘⇧P", "Del"])
        #expect(paragraph.map(\.startsGroup) == [false, false, true, false, false])
        let pageLink = PopupMenuItem.blockMenuItems(for: .pageLink)
        #expect(pageLink.map(\.title) == ["Преобразовать в", "Цвет", "Переместить в", "Удалить"])
        #expect(pageLink.map(\.startsGroup) == [false, false, true, false])
        #expect(EditorKeyBindings.command(characters: "p", modifiers: [.command, .shift]) == .moveBlocksToPage)
    }

    @Test("Пункт меню блока просит перенести этот блок; меню закрыто, у просьбы — место меню")
    func menuItemRequestsBlock() throws {
        let editor = try EditorFixture([.paragraph("один"), .paragraph("два"), .paragraph("три")])
        var requests: [SubpageRequest] = []
        editor.textView.onSubpageRequest = { requests.append($0) }
        editor.textView.openBlockMenu(forBlock: editor.document.blocks[1].id, below: NSRect(x: 100, y: 500, width: 20, height: 20))

        editor.step { editor.textView.popups.choose(.moveTo) }

        #expect(!editor.textView.popups.isOpen)
        guard case .moveBlocks(let ids, let anchor)? = requests.last else { Issue.record("нет просьбы: \(requests)"); return }
        #expect(ids == [editor.document.blocks[1].id])
        #expect(anchor != nil)
    }

    @Test("Меню блока внутри выделения переносит все выделенные блоки")
    func menuItemOnSelectionRequestsSelection() throws {
        let editor = try EditorFixture([.paragraph("один"), .paragraph("два"), .paragraph("три")])
        var requests: [SubpageRequest] = []
        editor.textView.onSubpageRequest = { requests.append($0) }
        editor.step { editor.textView.selectBlocks(0..<2) }
        editor.textView.openBlockMenu(forBlock: editor.document.blocks[1].id, below: NSRect(x: 100, y: 500, width: 20, height: 20))

        editor.step { editor.textView.popups.choose(.moveTo) }

        guard case .moveBlocks(let ids, _)? = requests.last else { Issue.record("нет просьбы: \(requests)"); return }
        #expect(ids == editor.document.blocks[0..<2].map(\.id))
    }

    @Test("⇧⌘P при выделенных блоках — просьба о них; без выделения редактор клавишу не берёт")
    func shortcutNeedsBlockSelection() throws {
        let editor = try EditorFixture([.paragraph("один"), .paragraph("два"), .paragraph("три")])
        var requests: [SubpageRequest] = []
        editor.textView.onSubpageRequest = { requests.append($0) }
        let event = try keyEvent(editor, "p", keyCode: 35, modifiers: [.command, .shift])

        editor.placeCaret(inBlock: 1, at: 1)
        #expect(!editor.textView.performKeyEquivalent(with: event), "Без выделенных блоков ⇧⌘P уходит в меню окна — страница")
        #expect(requests.isEmpty)

        editor.step { editor.textView.selectBlocks(1..<3) }
        #expect(editor.textView.performKeyEquivalent(with: event))
        guard case .moveBlocks(let ids, let anchor)? = requests.last else { Issue.record("нет просьбы: \(requests)"); return }
        #expect(ids == editor.document.blocks[1..<3].map(\.id))
        #expect(anchor == nil, "Окно покажет выбор у верхней полосы")
    }
}
