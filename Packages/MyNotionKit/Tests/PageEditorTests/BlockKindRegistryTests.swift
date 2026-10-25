import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// Реестр типов блоков (plan.md, Structure Decision): всё о типе — в его описателе, файл на тип в `BlockKinds/`.
/// Меню «/», быстрые символы, маркеры, подсказки и снимки галереи собираются из описателей.
@MainActor
@Suite("Реестр типов блоков")
struct BlockKindRegistryTests {
    @Test("У каждого BlockKind есть описатель, ровно один")
    func everyKindHasDescriptor() {
        #expect(BlockKindRegistry.all.map(\.kind).sorted { $0.rawValue < $1.rawValue }
                == BlockKind.allCases.sorted { $0.rawValue < $1.rawValue })
        for kind in BlockKind.allCases {
            #expect(BlockKindRegistry.descriptor(for: kind).kind == kind)
        }
    }

    @Test("Меню «/» собирается из описателей; типы 001 — как раньше, по порядку")
    func slashMenuFromDescriptors() {
        let menuKinds = BlockKindRegistry.all.compactMap { $0.menuItem == nil ? nil : $0.kind }
        #expect(PopupMenuItem.blockKinds.map(\.identifier) == menuKinds.map(\.rawValue))
        #expect(Array(PopupMenuItem.blockKinds.prefix(7)).map(\.title)
                == ["Текст", "Заголовок 1", "Заголовок 2", "Заголовок 3", "Маркированный список", "Нумерованный список", "Чекбокс"])
        #expect(PopupMenuItem.slashItems(matching: "заг").map(\.identifier) == ["heading1", "heading2", "heading3"])
        #expect(PopupMenuItem.blockKinds.first { $0.identifier == "checkbox" }?.shortcut == "[]")
    }

    @Test("Быстрые символы собираются из описателей; 001 — как раньше")
    func shortcutsFromDescriptors() {
        let expected: [String: BlockKind] = ["#": .heading1, "##": .heading2, "###": .heading3, "-": .bulletItem, "*": .bulletItem,
                                             "1.": .numberedItem, "[]": .checkbox, "[ ]": .checkbox]
        for (prefix, kind) in expected {
            #expect(MarkdownShortcuts.kind(forTypedPrefix: prefix) == kind, "\(prefix)")
        }
        #expect(MarkdownShortcuts.kind(forTypedPrefix: "текст") == nil)
        for descriptor in BlockKindRegistry.all {
            for prefix in descriptor.markdownShortcuts {
                #expect(MarkdownShortcuts.kind(forTypedPrefix: prefix) == descriptor.kind, "\(prefix) → \(descriptor.kind)")
            }
        }
    }

    @Test("Подстраница есть — её название; стёрта или в корзине — «Удалённая страница», как у упоминания; ещё не пришла — «Страница загружается»")
    func pageLinkToMissingPage() throws {
        let live = UUID(), gone = UUID(), trashed = UUID()
        let fixture = try EditorFixture([EditorFixture.Spec(kind: .pageLink, link: live), EditorFixture.Spec(kind: .pageLink, link: gone),
                                         EditorFixture.Spec(kind: .pageLink, link: trashed)])
        let blocks = fixture.document.blocks
        let view = fixture.textView
        view.linkedPages = [live: LinkedPage(title: "Проекты", icon: "📘")]
        view.mentionDirectory = MentionDirectory(pages: view.linkedPages, trashedPageIds: [trashed])
        #expect(view.decoration(for: blocks[0]) == .pageLink(MentionDisplay(title: "Проекты", icon: "📘", state: .page)))
        #expect(view.decoration(for: blocks[1]) == .pageLink(MentionDisplay(title: "Удалённая страница", icon: nil, state: .deleted)))
        #expect(view.decoration(for: blocks[2]) == .pageLink(MentionDisplay(title: "Удалённая страница", icon: nil, state: .deleted)))
        view.mentionDirectory.expectsMissingPages = true
        #expect(view.decoration(for: blocks[1]) == .pageLink(MentionDisplay(title: "Страница загружается", icon: nil, state: .loading)))
    }

    @Test("Маркеры, стиль текста и подсказки — из описателей")
    func decorationsFromDescriptors() throws {
        let fixture = try EditorFixture([.bullet("пункт"), .numbered("один"), .numbered("два"), .checkbox("дело", checked: true),
                                         .paragraph("текст"), .heading(1, "заголовок")])
        let blocks = fixture.document.blocks
        #expect(fixture.textView.decoration(for: blocks[0]) == .bullet("•"))
        #expect(fixture.textView.decoration(for: blocks[2]) == .number("2."))
        #expect(fixture.textView.decoration(for: blocks[3]) == .checkbox(checked: true))
        #expect(fixture.textView.decoration(for: blocks[4]) == nil)
        #expect(fixture.textView.decoration(for: blocks[5]) == nil)
        #expect(PageTextStorageMapper.textStyle(of: .heading2) == .heading2)
        #expect(PageTextStorageMapper.textStyle(of: .checkbox) == .listItem)
        #expect(BlockKind.checkbox.hasMarkerColumn && !BlockKind.paragraph.hasMarkerColumn)
        #expect(PageTextView.emptyBlockHint(for: .checkbox) == "Задача")
        #expect(PageTextView.emptyBlockHint(for: .pageLink) == nil)
        #expect(MarkdownShortcuts.exitsOnEmptyEnter(.bulletItem) && !MarkdownShortcuts.exitsOnEmptyEnter(.paragraph))
    }

    @Test("Рисователи по типу: у блоков 001 их нет, у заголовков — только стрелка и подпись свёрнутого")
    func paintersHook() {
        for kind in [BlockKind.paragraph, .bulletItem, .numberedItem, .checkbox, .pageLink] {
            #expect(BlockKindRegistry.descriptor(for: kind).painters.isEmpty)
        }
        for kind in [BlockKind.heading1, .heading2, .heading3] {
            #expect(BlockKindRegistry.descriptor(for: kind).painters.map { "\(type(of: $0))" } == ["HeadingFoldPainter"])
        }
    }
}
