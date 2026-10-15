import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor

/// Один текст на страницу, абзац = блок (research R2): блоки → текст с атрибутами абзацев → блоки без потерь;
/// правки текста уходят в `PageDocument` как правки блоков.
@MainActor
@Suite("Текст страницы и блоки")
struct PageTextMappingTests {
    let folder: TemporaryEditorFolder
    let store: NotesStore
    let pageId: UUID
    let subpageId: UUID

    init() throws {
        folder = try TemporaryEditorFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        (pageId, subpageId) = try store.write { tx in
            let page = try tx.createPage(title: "Разбор")
            let subpage = try tx.createPage(title: "Подстраница", parentId: page.id)
            return (page.id, subpage.id)
        }
    }

    /// Страница с блоками всех типов и оформлением, включая эмодзи (смещения в UTF-16).
    private func pageWithEveryKind() throws -> [Block] {
        try store.write { tx in
            let placeholder = try #require(try tx.blocks(ofPage: pageId).first)
            try tx.deleteBlock(placeholder.id)
            var key: FractionalSortKey?
            func add(_ kind: BlockKind, _ text: InlineText, indent: Int = 0, checked: Bool = false, link: UUID? = nil) throws {
                key = .between(key, nil)
                try tx.insertBlock(Block(pageId: pageId, kind: kind, text: text, indent: indent, isChecked: checked, linkedPageId: link, sortKey: key!))
            }
            try add(.paragraph, InlineText("Привет 👋 **мир** и `код`", runs: [
                StyledRun(start: 0, length: 6, style: .italic),
                StyledRun(start: 7, length: 2, style: .strikethrough),
                StyledRun(start: 10, length: 8, style: .bold),
                StyledRun(start: 20, length: 5, style: .code),
                StyledRun(start: 12, length: 3, style: .link(URL(string: "https://kurilov.cloud")!)),
            ]))
            try add(.heading1, InlineText("Заголовок 1"))
            try add(.heading2, InlineText("Заголовок 2"))
            try add(.heading3, InlineText("Заголовок 3"))
            try add(.bulletItem, InlineText("пункт"), indent: 2)
            try add(.numberedItem, InlineText("номер"), indent: 1)
            try add(.checkbox, InlineText("готово"), indent: 3, checked: true)
            try add(.pageLink, .empty, link: subpageId)
            try add(.paragraph, .empty)
            return try tx.blocks(ofPage: pageId)
        }
    }

    private func openEditor() throws -> (PageDocument, NSTextStorage, PageTextStorageMapper) {
        let document = try PageDocument(content: #require(try store.pageContent(pageId)))
        let storage = NSTextStorage()
        let mapper = PageTextStorageMapper(document: document, textStorage: storage)
        mapper.load()
        return (document, storage, mapper)
    }

    private func blockId(at location: Int, in storage: NSTextStorage) -> UUID? {
        storage.attribute(.blockID, at: location, effectiveRange: nil) as? UUID
    }

    // MARK: Без потерь

    @Test("Блоки → текст → блоки: все поля и оформление на месте")
    func roundTripKeepsEveryField() throws {
        let blocks = try pageWithEveryKind()
        let text = PageTextStorageMapper.attributedText(for: blocks)
        let drafts = PageTextStorageMapper.blockDrafts(in: text)

        #expect(drafts.count == blocks.count)
        for (draft, block) in zip(drafts, blocks) {
            #expect(draft.id == block.id)
            #expect(draft.kind == block.kind)
            #expect(draft.text == block.text.normalized(), "Текст и оформление блока \(block.kind)")
            #expect(draft.indent == block.indent)
            #expect(draft.isChecked == block.isChecked)
            #expect(draft.linkedPageId == block.linkedPageId)
        }
    }

    @Test("Каждый абзац текста помечен id своего блока")
    func everyParagraphCarriesItsBlockId() throws {
        let blocks = try pageWithEveryKind()
        let text = PageTextStorageMapper.attributedText(for: blocks)
        let string = text.string as NSString

        #expect(text.string == blocks.map(\.text.string).joined(separator: "\n"))
        var location = 0
        for block in blocks.dropLast() {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            for index in paragraph.location..<NSMaxRange(paragraph) {
                #expect(text.attribute(.blockID, at: index, effectiveRange: nil) as? UUID == block.id)
            }
            location = NSMaxRange(paragraph)
        }
    }

    // MARK: Правки текста → правки блоков

    @Test("Набор в абзаце меняет только его блок")
    func typingChangesOnlyItsBlock() throws {
        let blocks = try pageWithEveryKind()
        let (document, storage, mapper) = try openEditor()
        let headingStart = (storage.string as NSString).range(of: "Заголовок 2").location

        storage.replaceCharacters(in: NSRange(location: headingStart + 9, length: 0), with: "ок")
        mapper.commitPendingEdits()

        #expect(document.blocks.map(\.id) == blocks.map(\.id))
        #expect(document.blocks[2].text.string == "Заголовокок 2")
        #expect(document.blocks[2].kind == .heading2)
        #expect(document.unsavedBlockIds == [blocks[2].id])
    }

    @Test("Enter делит блок: начало остаётся в нём, конец — в новом блоке того же типа")
    func enterSplitsBlock() throws {
        let blocks = try pageWithEveryKind()
        let (document, storage, mapper) = try openEditor()
        let itemStart = (storage.string as NSString).range(of: "пункт").location

        storage.replaceCharacters(in: NSRange(location: itemStart + 2, length: 0), with: "\n")
        mapper.commitPendingEdits()

        #expect(document.blocks.count == blocks.count + 1)
        let original = document.blocks[4], created = document.blocks[5]
        #expect(original.id == blocks[4].id)
        #expect(original.text.string == "пу")
        #expect(created.id != blocks[4].id && !blocks.contains { $0.id == created.id })
        #expect(created.text.string == "нкт")
        #expect(created.kind == .bulletItem && created.indent == 2)
        #expect(original.sortKey < created.sortKey && created.sortKey < document.blocks[6].sortKey)
        #expect(blockId(at: itemStart + 3, in: storage) == created.id, "Новый абзац помечен id нового блока")
    }

    @Test("⌫ в начале блока склеивает его с предыдущим")
    func backspaceAtStartMergesWithPrevious() throws {
        let blocks = try pageWithEveryKind()
        let (document, storage, mapper) = try openEditor()
        let numberStart = (storage.string as NSString).range(of: "номер").location

        storage.replaceCharacters(in: NSRange(location: numberStart - 1, length: 1), with: "")
        mapper.commitPendingEdits()

        #expect(document.blocks.count == blocks.count - 1)
        #expect(document.blocks[4].id == blocks[4].id)
        #expect(document.blocks[4].text.string == "пунктномер")
        #expect(!document.blocks.contains { $0.id == blocks[5].id })
        #expect(blockId(at: numberStart + 2, in: storage) == blocks[4].id, "Склеенный абзац целиком помечен одним id")
    }

    @Test("Вставка нескольких абзацев посреди блока")
    func pastingParagraphsInsideBlock() throws {
        let blocks = try pageWithEveryKind()
        let (document, storage, mapper) = try openEditor()
        let headingStart = (storage.string as NSString).range(of: "Заголовок 3").location

        storage.replaceCharacters(in: NSRange(location: headingStart + 9, length: 0), with: " один\nдва\nтри")
        mapper.commitPendingEdits()

        #expect(document.blocks.count == blocks.count + 2)
        #expect(document.blocks[3].id == blocks[3].id)
        #expect(document.blocks[3...5].map(\.text.string) == ["Заголовок один", "два", "три 3"])
        #expect(Set(document.blocks.map(\.id)).count == document.blocks.count, "id блоков не повторяются")
    }

    @Test("Выделение через несколько блоков и набор поверх него")
    func replacingSelectionAcrossBlocks() throws {
        let blocks = try pageWithEveryKind()
        let (document, storage, mapper) = try openEditor()
        let string = storage.string as NSString
        let from = string.range(of: "Заголовок 1").location + 3
        let to = string.range(of: "Заголовок 3").location + 3

        storage.replaceCharacters(in: NSRange(location: from, length: to - from), with: "—")
        mapper.commitPendingEdits()

        #expect(document.blocks.count == blocks.count - 2)
        #expect(document.blocks[1].id == blocks[1].id)
        #expect(document.blocks[1].text.string == "Заг—оловок 3")
        #expect(!document.blocks.contains { $0.id == blocks[2].id || $0.id == blocks[3].id })
    }

    @Test("Набор в пустом последнем абзаце остаётся в его блоке")
    func typingIntoTrailingEmptyParagraphKeepsItsBlock() throws {
        let blocks = try pageWithEveryKind()
        let (document, storage, mapper) = try openEditor()

        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "конец")
        mapper.commitPendingEdits()

        #expect(document.blocks.map(\.id) == blocks.map(\.id))
        #expect(document.blocks.last?.text.string == "конец")
        #expect(document.blocks.last?.kind == .paragraph)
    }

    @Test("Смена атрибутов без правки текста блоки не трогает")
    func attributeOnlyChangeIsIgnored() throws {
        _ = try pageWithEveryKind()
        let (document, storage, mapper) = try openEditor()

        storage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 3))
        mapper.commitPendingEdits()

        #expect(document.unsavedBlockIds.isEmpty)
        #expect(!document.hasUnsavedChanges)
    }
}

/// Пустая папка на время теста.
final class TemporaryEditorFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotionEditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var databaseURL: URL { url.appendingPathComponent("MyNotion.sqlite") }

    deinit { try? FileManager.default.removeItem(at: url) }
}
