import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor

/// Справочник страниц для окна «@» в тестах.
struct FixedPageLookup: PageLookup {
    var pages: [PageLookupResult]

    func pages(matching query: String, limit: Int) -> [PageLookupResult] {
        let query = query.lowercased()
        return Array(pages.filter { query.isEmpty || $0.title.lowercased().contains(query) }.prefix(limit))
    }
}

/// Упоминания страниц «@» и «[[» (contracts/blocks-and-keys.md, «Упоминания»; tasks.md T053).
@MainActor
@Suite("Упоминания страниц")
struct MentionTests {
    let plan = UUID()
    let ideas = UUID()

    func editor(_ text: String = "") throws -> EditorFixture {
        let editor = try EditorFixture([.paragraph(text)])
        editor.textView.pageLookup = FixedPageLookup(pages: [
            PageLookupResult(pageId: plan, title: "План", icon: "📘", path: ["Работа"]),
            PageLookupResult(pageId: ideas, title: "Идеи", icon: nil, path: []),
        ])
        editor.textView.mentionDirectory = MentionDirectory(pages: [plan: LinkedPage(title: "План", icon: "📘"),
                                                                    ideas: LinkedPage(title: "Идеи")])
        return editor
    }

    func mentions(in block: Block) -> [UUID] {
        block.text.runs.compactMap { if case .mention(let id) = $0.style { id } else { nil } }
    }

    @Test("«@» открывает окно, набор ищет страницы, Enter вставляет упоминание на месте «@» и набора")
    func atInsertsMention() throws {
        let editor = try editor()
        editor.placeCaret(inBlock: 0)
        editor.type("Смотри @пл")
        let picker = editor.textView.mentionPicker
        #expect(picker.isOpen)
        #expect(picker.visibleItems.compactMap(\.pageId) == [plan])
        editor.press(#selector(NSResponder.insertNewline(_:)))

        #expect(!picker.isOpen)
        let block = editor.document.blocks[0]
        #expect(block.text.string == "Смотри \u{FFFC}")
        #expect(mentions(in: block) == [plan])
        #expect(editor.textView.selectedRange() == NSRange(location: 8, length: 0))
    }

    @Test("«[[» открывает то же окно, но без дат; после выбора скобок не остаётся")
    func bracketsInsertMention() throws {
        let editor = try editor()
        editor.placeCaret(inBlock: 0)
        editor.type("см [[ид")
        let picker = editor.textView.mentionPicker
        #expect(picker.isOpen)
        #expect(picker.visibleItems.allSatisfy { $0.pageId != nil })
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(editor.document.blocks[0].text.string == "см \u{FFFC}")
        #expect(mentions(in: editor.document.blocks[0]) == [ideas])
    }

    @Test("Под «@» без набора — даты; «завтра» вставляет дату")
    func atOffersDates() throws {
        let editor = try editor()
        editor.textView.now = { DateQueryTests.now }
        editor.textView.calendar = DateQueryTests.calendar
        editor.placeCaret(inBlock: 0)
        editor.type("@")
        #expect(editor.textView.mentionPicker.visibleItems.filter { $0.pageId == nil }.map(\.title) == ["Сегодня", "Завтра", "Вчера", "Через неделю"])
        editor.type("завтра")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        let run = try #require(editor.document.blocks[0].text.runs.first)
        guard case .date(let date) = run.style else { Issue.record("не дата: \(run.style)"); return }
        #expect(date.start == "2026-10-20")
        #expect(editor.document.blocks[0].text.string == "\u{FFFC}")
    }

    @Test("Esc закрывает окно и оставляет набранное; «@» внутри слова окна не открывает")
    func escapeAndMidWord() throws {
        let editor = try editor()
        editor.placeCaret(inBlock: 0)
        editor.type("@пл")
        editor.press(#selector(NSResponder.cancelOperation(_:)))
        #expect(!editor.textView.mentionPicker.isOpen)
        #expect(editor.document.blocks[0].text.string == "@пл")
        editor.type(" mail@host")
        #expect(!editor.textView.mentionPicker.isOpen)
    }

    @Test("Название и иконка — из справочника; переименование видно сразу; корзина и отсутствие — свои надписи")
    func directoryDrivesLook() throws {
        let editor = try editor()
        editor.placeCaret(inBlock: 0)
        editor.type("@пл")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        let view = editor.textView
        #expect(view.mentionDirectory.display(of: plan) == MentionDisplay(title: "План", icon: "📘", state: .page))
        let before = try #require(view.atomAttachment(at: 0) as? MentionAttachment).size(in: view)

        view.mentionDirectory = MentionDirectory(pages: [plan: LinkedPage(title: "План на длинный год", icon: "🚀")])
        #expect(view.mentionDirectory.display(of: plan) == MentionDisplay(title: "План на длинный год", icon: "🚀", state: .page))
        let after = try #require(view.atomAttachment(at: 0) as? MentionAttachment).size(in: view)
        #expect(after.width > before.width)

        view.mentionDirectory = MentionDirectory(pages: [:], trashedPageIds: [plan])
        #expect(view.mentionDirectory.display(of: plan).title == "Удалённая страница")
        #expect(view.mentionDirectory.display(of: plan).state == .deleted)
        view.mentionDirectory = MentionDirectory(pages: [:], expectsMissingPages: true)
        #expect(view.mentionDirectory.display(of: plan) == MentionDisplay(title: "Страница загружается", icon: nil, state: .loading))
        view.mentionDirectory = MentionDirectory(pages: [:], expectsMissingPages: false)
        #expect(view.mentionDirectory.display(of: plan).state == .deleted)
    }

    @Test("Курсор перешагивает упоминание целиком, ⌫ удаляет его целиком")
    func atomicCaretAndBackspace() throws {
        let editor = try editor()
        editor.placeCaret(inBlock: 0)
        editor.type("а @пл")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        editor.type("б")
        #expect(editor.document.blocks[0].text.string == "а \u{FFFC}б")
        editor.placeCaret(inBlock: 0, at: 3)
        editor.press(#selector(NSResponder.moveLeft(_:)))
        #expect(editor.textView.selectedRange().location == 2)
        editor.press(#selector(NSResponder.moveRight(_:)))
        #expect(editor.textView.selectedRange().location == 3)
        editor.step { editor.textView.deleteBackward(nil) }
        #expect(editor.document.blocks[0].text.string == "а б")
        #expect(editor.document.blocks[0].text.runs.isEmpty)
        editor.undo()
        #expect(mentions(in: editor.document.blocks[0]) == [plan])
    }

    @Test("Простой текст при копировании — название страницы и дата словами")
    func plainTextCopy() throws {
        let editor = try editor()
        editor.textView.calendar = DateQueryTests.calendar
        editor.placeCaret(inBlock: 0)
        editor.type("к @пл")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        editor.type(" @25.10.2026")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        editor.textView.selectAll(nil)
        let board = NSPasteboard(name: NSPasteboard.Name("MentionTests-\(UUID().uuidString)"))
        _ = editor.textView.writeSelection(to: board, types: [.string])
        #expect(board.string(forType: .string) == "к План @25 октября 2026")
    }

    @Test("Копия даты вставляется с новым id (новое напоминание); ⌘Z возвращает прежний текст")
    func pastedDateGetsNewId() throws {
        let editor = try editor()
        editor.textView.now = { DateQueryTests.now }
        editor.textView.calendar = DateQueryTests.calendar
        editor.placeCaret(inBlock: 0)
        editor.type("@завтра")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        editor.type(" ")
        func dateIds() -> [UUID] {
            editor.document.blocks.flatMap { $0.text.runs.compactMap { if case .date(let d) = $0.style { d.id } else { nil } } }
        }
        let original = try #require(dateIds().first)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 1))
        let board = NSPasteboard(name: NSPasteboard.Name("MentionTests-\(UUID().uuidString)"))
        _ = editor.textView.writeSelection(to: board, types: editor.textView.writablePasteboardTypes)
        editor.placeCaret(inBlock: 0, at: nil)
        editor.step { editor.textView.paste(from: board) }
        let ids = dateIds()
        #expect(ids.count == 2)
        #expect(ids.first == original)
        #expect(ids.last != original)
        editor.undo()
        #expect(dateIds() == [original])
    }

    @Test("Щелчок по упоминанию открывает страницу")
    func clickOpensPage() throws {
        let editor = try editor()
        editor.placeCaret(inBlock: 0)
        editor.type("@пл")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        var opened: UUID?
        editor.textView.onOpenPage = { opened = $0 }
        #expect(editor.textView.openAtom(atCharacter: 0))
        #expect(opened == plan)
    }

    @Test("Правка даты из календарика заменяет её в тексте с тем же id; «Удалить» стирает; ⌘Z возвращает")
    func editAndDeleteDate() throws {
        let editor = try editor()
        editor.textView.now = { DateQueryTests.now }
        editor.textView.calendar = DateQueryTests.calendar
        editor.placeCaret(inBlock: 0)
        editor.type("созвон @завтра")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        func date() -> DateMention? {
            editor.document.blocks[0].text.runs.lazy.compactMap { if case .date(let d) = $0.style { d } else { nil } }.first
        }
        let original = try #require(date())
        let reminded = original.edited(includesTime: true, time: (10, 0), reminder: .atEvent)
        editor.step { editor.textView.replaceDate(original.id, with: reminded) }
        #expect(date() == reminded)
        #expect(editor.document.blocks[0].text.string == "созвон \u{FFFC}")
        editor.step { editor.textView.replaceDate(original.id, with: nil) }
        #expect(date() == nil)
        #expect(editor.document.blocks[0].text.string == "созвон ")
        editor.undo()
        #expect(date() == reminded)
    }
}
