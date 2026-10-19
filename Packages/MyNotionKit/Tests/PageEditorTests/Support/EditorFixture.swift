import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor

/// Страница с заданными блоками, открытая в настоящем `PageTextView` в невидимом окне.
/// Действия идут через те же методы, что вызывают клавиши и мышь; каждый шаг — отдельная группа отмены.
@MainActor
final class EditorFixture {
    struct Spec {
        var kind: BlockKind = .paragraph
        var text: String = ""
        var indent: Int = 0
        var checked: Bool = false
        var link: UUID?

        static func paragraph(_ text: String = "") -> Spec { Spec(kind: .paragraph, text: text) }
        static func heading(_ level: Int, _ text: String) -> Spec {
            Spec(kind: [.heading1, .heading2, .heading3][level - 1], text: text)
        }
        static func bullet(_ text: String, indent: Int = 0) -> Spec { Spec(kind: .bulletItem, text: text, indent: indent) }
        static func numbered(_ text: String, indent: Int = 0) -> Spec { Spec(kind: .numberedItem, text: text, indent: indent) }
        static func checkbox(_ text: String, indent: Int = 0, checked: Bool = false) -> Spec {
            Spec(kind: .checkbox, text: text, indent: indent, checked: checked)
        }
    }

    let folder: TemporaryEditorFolder
    let store: NotesStore
    let pageId: UUID
    let document: PageDocument
    let textView: PageTextView
    let window: NSWindow
    let undoManager = UndoManager()

    init(_ specs: [Spec] = [.paragraph()], icon: String? = nil) throws {
        folder = try TemporaryEditorFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        pageId = try store.write { tx in
            var page = try tx.createPage(title: "Блоки")
            if let icon {
                page.icon = icon
                try tx.updatePage(page)
            }
            for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            for spec in specs {
                key = .between(key, nil)
                try tx.insertBlock(Block(pageId: page.id, kind: spec.kind, text: InlineText(spec.text), indent: spec.indent,
                                         isChecked: spec.checked, linkedPageId: spec.link, sortKey: key!))
            }
            return page.id
        }
        document = try PageDocument(content: #require(try store.pageContent(pageId)))
        textView = PageTextView(document: document, initialFocus: .body)
        undoManager.groupsByEvent = false
        textView.fallbackUndoManager = undoManager
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.documentView = textView
        textView.frame.size.width = 1200
        window.contentView = scroll
        window.makeFirstResponder(textView)
    }

    /// Та же страница из базы заново: в новом документе и новом окне (например, после правки записей в обход редактора).
    init(reopening other: EditorFixture) throws {
        folder = other.folder
        store = other.store
        pageId = other.pageId
        document = try PageDocument(content: #require(try store.pageContent(pageId)))
        textView = PageTextView(document: document, initialFocus: .body)
        undoManager.groupsByEvent = false
        textView.fallbackUndoManager = undoManager
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.documentView = textView
        textView.frame.size.width = 1200
        window.contentView = scroll
        window.makeFirstResponder(textView)
    }

    // MARK: Шаги

    /// Одно действие пользователя — одна группа отмены, как одно событие клавиатуры.
    func step(_ action: () -> Void) {
        undoManager.beginUndoGrouping()
        action()
        undoManager.endUndoGrouping()
    }

    /// Набрать текст посимвольно в позиции курсора.
    func type(_ text: String) {
        for character in text {
            step { textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
    }

    func press(_ selector: Selector) {
        step { textView.doCommand(by: selector) }
    }

    func perform(_ command: EditorCommand) {
        step { textView.perform(command) }
    }

    func undo() { undoManager.undo() }
    func redo() { undoManager.redo() }

    /// Курсор в блок `index` со смещением `offset` от начала его текста (`nil` — в конец).
    func placeCaret(inBlock index: Int, at offset: Int? = 0) {
        let location = textLocation(ofBlock: index) + (offset ?? (document.blocks[index].text.string as NSString).length)
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    func select(inBlock index: Int, _ substring: String) {
        let start = textLocation(ofBlock: index)
        let found = (document.blocks[index].text.string as NSString).range(of: substring)
        precondition(found.location != NSNotFound, "Нет «\(substring)» в блоке \(index)")
        textView.setSelectedRange(NSRange(location: start + found.location, length: found.length))
    }

    /// Начало абзаца блока в тексте.
    func textLocation(ofBlock index: Int) -> Int {
        let string = textView.string as NSString
        var location = 0
        for _ in 0..<index {
            location = NSMaxRange(string.paragraphRange(for: NSRange(location: location, length: 0)))
        }
        return location
    }

    // MARK: Проверки

    var kinds: [BlockKind] { document.blocks.map(\.kind) }
    var texts: [String] { document.blocks.map(\.text.string) }
    var indents: [Int] { document.blocks.map(\.indent) }

    /// Записать документ и прочитать страницу из базы заново.
    func savedBlocks() throws -> [Block] {
        let autosave = AutosaveCoordinator(document: document, store: store, scheduler: IdleAutosaveScheduler())
        precondition(autosave.saveNow(), "Запись не удалась")
        autosave.stop()
        return try store.pageContent(pageId)?.blocks ?? []
    }
}

/// Автосохранение, которое само не срабатывает: тест пишет через `saveNow()`.
@MainActor
final class IdleAutosaveScheduler: AutosaveScheduler {
    var now: Duration { .zero }
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> any ScheduledAutosave { Never() }

    final class Never: ScheduledAutosave {
        func cancel() {}
    }
}
