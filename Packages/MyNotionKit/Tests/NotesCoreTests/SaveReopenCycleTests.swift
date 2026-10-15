import Foundation
import Testing
@testable import NotesCore

/// SC-004: в 100 из 100 проверок «набрать текст → закрыть → открыть» текст совпадает полностью.
/// Каждый цикл: случайные правки во всех полях → закрыть документ и базу → открыть → сверить.
@MainActor
@Suite("Сто циклов «записать — закрыть — открыть»")
struct SaveReopenCycleTests {
    static let cycles = 100

    @Test("100 циклов без единого расхождения")
    func hundredCyclesMatchExactly() throws {
        let folder = try TemporaryFolder()
        var random = CycleRandom(seed: 0x5EED_0004)

        let (pageId, subpageIds) = try withStore(folder) { store in
            try store.write { tx in
                let page = try tx.createPage(title: "Циклы", icon: "🔁")
                let subpages = try (0..<3).map { try tx.createPage(title: "Подстраница \($0)", parentId: page.id).id }
                return (page.id, subpages)
            }
        }

        for cycle in 1...Self.cycles {
            let expected: PageContent = try withStore(folder) { store in
                let documents = OpenDocuments(store: store, scheduler: ManualAutosaveScheduler())
                let document = try documents.open(pageId)

                document.setTitle(random.text(maxLength: 40))
                let existing = document.blocks.map(\.id)
                let drafts = (0..<random.int(1...12)).map { _ in
                    random.draft(reusing: existing, linkTargets: subpageIds)
                }
                document.replaceBlocks(after: nil, before: nil, with: drafts)
                if let edited = document.blocks.randomElement(using: &random.generator) {
                    document.setText(random.inlineText(), ofBlock: edited.id)
                }

                let snapshot = PageContent(page: document.page, blocks: document.blocks)
                documents.release(pageId)
                return snapshot
            }

            let reopened = try #require(try withStore(folder) { try $0.pageContent(pageId) })
            #expect(reopened.page.title == expected.page.title, "Цикл \(cycle): название")
            #expect(reopened.page.icon == "🔁", "Цикл \(cycle): иконка")
            #expect(reopened.blocks.map(BlockFields.init) == expected.blocks.map(BlockFields.init), "Цикл \(cycle): блоки")
        }
    }

    /// Открыть базу, сделать дело и закрыть её.
    private func withStore<T>(_ folder: TemporaryFolder, _ body: (NotesStore) throws -> T) throws -> T {
        let database = try AppDatabase.open(at: folder.databaseURL)
        defer { database.close() }
        return try body(NotesStore(database: database, clock: HybridLogicalClock(deviceId: UUID())))
    }
}

/// Всё, что Юрий видит в блоке, и его место.
private struct BlockFields: Equatable, CustomStringConvertible {
    let id: UUID
    let kind: BlockKind
    let text: InlineText
    let indent: Int
    let isChecked: Bool
    let linkedPageId: UUID?

    init(_ block: Block) {
        id = block.id
        kind = block.kind
        text = block.text
        indent = block.indent
        isChecked = block.isChecked
        linkedPageId = block.linkedPageId
    }

    var description: String { "\(kind.rawValue)[\(indent)\(isChecked ? "✓" : "")] \(text.string)" }
}

/// Повторяемые случайные правки: кириллица, латиница, эмодзи, оформление во всех стилях.
private struct CycleRandom {
    var generator: SeededGenerator

    init(seed: UInt64) {
        generator = SeededGenerator(state: seed)
    }

    private static let alphabet: [String] = "абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВЁЯabcdefxyzXYZ0123456789 ,.!?—«»-".map(String.init) +
        ["😀", "👨‍👩‍👧", "🇷🇺", "é", "ß", "\t"]

    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &generator) }

    mutating func bool() -> Bool { Bool.random(using: &generator) }

    mutating func text(maxLength: Int) -> String {
        (0..<int(0...maxLength)).map { _ in Self.alphabet.randomElement(using: &generator)! }.joined()
    }

    mutating func inlineText() -> InlineText {
        let string = text(maxLength: 60)
        let length = (string as NSString).length
        guard length > 0 else { return InlineText(string) }
        var runs: [StyledRun] = []
        let styles: [InlineStyle] = [.bold, .italic, .strikethrough, .code, .link(URL(string: "https://kurilov.cloud/\(int(1...9))")!)]
        for style in styles where bool() {
            let start = int(0...(length - 1))
            runs.append(StyledRun(start: start, length: int(1...(length - start)), style: style))
        }
        return InlineText(string, runs: runs).normalized()
    }

    mutating func draft(reusing existing: [UUID], linkTargets: [UUID]) -> BlockDraft {
        let kind = BlockKind.allCases.randomElement(using: &generator)!
        let reuse = !existing.isEmpty && bool()
        return BlockDraft(
            id: reuse ? existing.randomElement(using: &generator) : nil,
            kind: kind,
            text: kind == .pageLink ? .empty : inlineText(),
            indent: kind.isHeading || kind == .pageLink ? 0 : int(Block.indentRange),
            isChecked: kind == .checkbox && bool(),
            linkedPageId: kind == .pageLink ? linkTargets.randomElement(using: &generator) : nil
        )
    }
}

/// Генератор с постоянным зерном (SplitMix64): прогон повторяется один в один.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
