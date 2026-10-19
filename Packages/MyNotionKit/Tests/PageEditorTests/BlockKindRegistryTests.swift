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

    @Test("Рисователи по типу: у блоков 001 их нет, точка вызова на месте")
    func paintersHook() {
        for kind in [BlockKind.paragraph, .heading1, .bulletItem, .numberedItem, .checkbox, .pageLink] {
            #expect(BlockKindRegistry.descriptor(for: kind).painters.isEmpty)
        }
    }
}
