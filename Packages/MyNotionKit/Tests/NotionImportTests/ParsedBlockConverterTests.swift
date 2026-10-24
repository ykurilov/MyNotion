import Foundation
import Testing
import NotesCore
@testable import NotionImport

/// Перевод разобранных блоков в блоки базы вынесен из импорта в `ParsedBlockConverter` (005, T032):
/// импорт через него даёт те же блоки, что давал прежний код, на всех выгрузках из фикстур.
@Suite("Перевод разобранных блоков: как прежний импорт")
struct ParsedBlockConverterTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)
    static let sources = [
        "notion-export/synthetic", "notion-export/synthetic-nested.zip", "notion-export/live-mynotion-comparison.zip",
        "notion-export/live-mynotion-002-blocks.zip", "NotionDatabases/synthetic", "NotionDatabases/no-subpages",
    ]

    @Test("Каждая страница каждой выгрузки — те же блоки", arguments: sources)
    func sameBlocksAsLegacyImport(source: String) throws {
        let prepared = try NotionExportUnpacker().prepare(Self.fixtures.appendingPathComponent(source))
        defer { prepared.discard() }
        var plan = try NotionExportReader().read(prepared.contentRoot)
        let databases = try NotionDatabaseReader().read(&plan)
        let ids = plan.pages.map(\.id)
        #expect(!plan.pages.isEmpty)
        for index in plan.pages.indices {
            let converted = NotionImporter.blocks(for: index, in: plan, databases: databases, ids: ids)
            let legacy = LegacyImportBlocks.blocks(for: index, in: plan, databases: databases, ids: ids)
            #expect(Self.comparable(converted) == Self.comparable(legacy), "страница «\(plan.pages[index].title)» в \(source)")
        }
    }

    @Test("Ссылка на страницу, упоминание, ссылка-карточка и пустой ввод")
    func convertsDirectly() {
        let pageId = UUID()
        let target = UUID()
        var link = ParsedBlock(kind: .pageLink, text: InlineText("План"))
        link.pagePath = "План.md"
        var url = ParsedBlock(kind: .paragraph, text: InlineText("https://example.com"))
        url.standaloneURL = URL(string: "https://example.com")
        let lost = ParsedBlock(kind: .pageLink, text: InlineText("Нет такой"))
        let blocks = ParsedBlockConverter.blocks(from: [link, url, lost], pageId: pageId,
                                                 linkTarget: { $0.pagePath == "План.md" ? .page(target) : nil },
                                                 mentionTarget: { _ in nil })
        #expect(blocks.map(\.kind) == [.pageLink, .bookmark, .paragraph])
        #expect(blocks[0].linkedPageId == target)
        #expect(blocks[1].props.url == URL(string: "https://example.com"))
        #expect(blocks[2].text.string == "Нет такой")
        #expect(blocks.allSatisfy { $0.pageId == pageId })
        #expect(ParsedBlockConverter.blocks(from: [], pageId: pageId, linkTarget: { _ in nil }, mentionTarget: { _ in nil }).isEmpty)
    }

    /// Блоки без случайных id: id и контейнер — по порядковому номеру блока в списке.
    static func comparable(_ blocks: [Block]) -> [Block] {
        let ordinal = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($1.id, $0) })
        func stable(_ position: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", position))! }
        return blocks.enumerated().map { position, block in
            Block(id: stable(position), pageId: block.pageId, kind: block.kind, text: block.text, indent: block.indent,
                  isChecked: block.isChecked, linkedPageId: block.linkedPageId, sortKey: block.sortKey,
                  containerId: block.containerId.map { ordinal[$0].map(stable) ?? $0 }, color: block.color, props: block.props)
        }
    }
}

/// Прежний код `NotionImporter.blocks(for:in:databases:ids:)` до выноса — образец для сравнения.
private enum LegacyImportBlocks {
    static func blocks(for index: Int, in plan: NotionExportPlan, databases: [Int: PlannedDatabase], ids: [UUID]) -> [Block] {
        let page = plan.pages[index]
        let pageId = ids[index]
        if databases[index] != nil { return [] }
        var result: [Block] = []
        var sortKey: FractionalSortKey?
        var linkedChildren: Set<Int> = []
        func append(_ kind: BlockKind, _ text: InlineText = .empty, indent: Int = 0, checked: Bool = false, link: UUID? = nil) {
            sortKey = .between(sortKey, nil)
            result.append(Block(pageId: pageId, kind: kind, text: text, indent: indent,
                                isChecked: kind == .checkbox && checked, linkedPageId: link, sortKey: sortKey!))
        }
        func appendRich(_ parsed: ParsedBlock) {
            sortKey = .between(sortKey, nil)
            let block = Block(id: parsed.id ?? .timeOrdered(), pageId: pageId, kind: parsed.kind, text: parsed.text, indent: parsed.indent,
                              isChecked: parsed.kind == .checkbox && parsed.isChecked, sortKey: sortKey!,
                              color: parsed.color, props: parsed.props)
            result.append(block)
            func appendContained(_ children: [ParsedBlock], in containerId: UUID) {
                var key: FractionalSortKey?
                for child in children {
                    key = .between(key, nil)
                    let text = child.mentions.isEmpty ? child.text : NotionImporter.resolvingMentions(in: child.text, mentions: child.mentions) { path in
                        plan.page(atPath: path, from: index).map { ids[$0] }
                    }
                    let inner = Block(id: child.id ?? .timeOrdered(), pageId: pageId, kind: child.kind, text: text, indent: child.indent,
                                      isChecked: child.kind == .checkbox && child.isChecked, sortKey: key!, containerId: containerId,
                                      color: child.color, props: child.props)
                    result.append(inner)
                    appendContained(child.contained, in: inner.id)
                }
            }
            appendContained(parsed.contained, in: block.id)
        }
        for var block in page.blocks {
            if !block.mentions.isEmpty {
                block.text = NotionImporter.resolvingMentions(in: block.text, mentions: block.mentions) { path in
                    plan.page(atPath: path, from: index).map { ids[$0] }
                }
            }
            if let target = NotionExportReader.linkedPage(block, from: index, in: plan) {
                if page.children.contains(target) { linkedChildren.insert(target) }
                let isInline = databases[target]?.schema.isInline == true && plan.pages[target].parent == index
                append(isInline ? .database : .pageLink, link: ids[target])
            } else if block.kind == .pageLink {
                append(.paragraph, block.text)
            } else if let url = block.standaloneURL, block.kind == .paragraph, ["http", "https"].contains(url.scheme?.lowercased()) {
                appendRich(NotionImporter.linkCard(for: url, text: block.text, indent: block.indent))
            } else if !block.color.isNone || !block.props.isEmpty || !block.contained.isEmpty {
                appendRich(block)
            } else {
                append(block.kind, block.text, indent: block.indent, checked: block.isChecked)
            }
        }
        for child in page.children where !linkedChildren.contains(child) {
            append(.pageLink, link: ids[child])
        }
        if result.isEmpty { append(.paragraph) }
        return result
    }
}
