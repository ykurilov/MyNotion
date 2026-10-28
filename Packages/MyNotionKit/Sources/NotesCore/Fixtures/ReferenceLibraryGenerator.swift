import Foundation

/// Эталонная база для замеров (research R13): 1 000 страниц до 10 уровней, 100 000 блоков
/// всех типов, одна страница на 1 000 блоков, текст на кириллице и латинице.
/// Содержимое одинаково при каждом запуске: случайность идёт от постоянного зерна.
/// Обычные тесты берут уменьшенный эталон той же формы (`Shape.compact`), полный — замеры и медленная группа.
public struct ReferenceLibraryGenerator: Sendable {
    /// Размеры эталона: страниц, блоков всего, глубина дерева и блоков на самой большой странице.
    public struct Shape: Sendable, Equatable {
        public let pageCount: Int
        public let blockCount: Int
        public let maxLevels: Int
        public let largePageBlockCount: Int

        public init(pageCount: Int, blockCount: Int, maxLevels: Int, largePageBlockCount: Int) {
            self.pageCount = pageCount
            self.blockCount = blockCount
            self.maxLevels = maxLevels
            self.largePageBlockCount = largePageBlockCount
        }

        /// Эталон замеров (research R13).
        public static let full = Shape(pageCount: 1_000, blockCount: 100_000, maxLevels: 10, largePageBlockCount: 1_000)
        /// Та же форма в двадцать раз меньше: все уровни и виды блоков, страница-великан крупнее остальных.
        public static let compact = Shape(pageCount: 100, blockCount: 5_000, maxLevels: 10, largePageBlockCount: 250)
    }

    public static let pageCount = Shape.full.pageCount
    public static let blockCount = Shape.full.blockCount
    public static let maxLevels = Shape.full.maxLevels
    public static let largePageBlockCount = Shape.full.largePageBlockCount

    public enum GenerationError: Error, LocalizedError {
        case fileExists(URL)

        public var errorDescription: String? {
            switch self {
            case .fileExists(let url): "Файл уже есть, эталон не записан поверх: \(url.path)"
            }
        }
    }

    private let seed: UInt64
    public let shape: Shape

    public init(seed: UInt64 = 20_261_015, shape: Shape = .full) {
        self.seed = seed
        self.shape = shape
    }

    /// Создать эталонную базу в новом файле. Существующий файл не трогается.
    public func generate(at url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw GenerationError.fileExists(url) }

        // Сначала во временный файл рядом: прерванная генерация не оставит половину эталона.
        let draftURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).draft-\(UUID().uuidString)")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: draftURL.path + suffix)
            }
        }
        let database = try AppDatabase.open(at: draftURL)
        try generate(into: NotesStore(database: database, clock: HybridLogicalClock(deviceId: UUID())))
        // Эталон пишется без подписчика поиска — индекс наполняется так же, как миграцией старой базы.
        try database.dbWriter.write { try SchemaMigrations.fillSearchIndex($0) }
        // Всё из журнала WAL — в основной файл: переносится только он.
        try database.dbWriter.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        database.close()
        try FileManager.default.moveItem(at: draftURL, to: url)
    }

    /// Записать эталон в хранилище одной транзакцией.
    public func generate(into store: NotesStore) throws {
        var random = SeededRandom(seed: seed)
        let plan = TreePlan(shape: shape, random: &random)
        let pageCount = shape.pageCount

        let largePageId = try store.write { transaction in
            let now = Date()
            var pageIds: [UUID] = []
            var lastChildKey: [Int: FractionalSortKey] = [:]
            var lastRootKey: FractionalSortKey?

            for index in 0..<pageCount {
                let parentIndex = plan.parents[index]
                let sortKey: FractionalSortKey
                if let parentIndex {
                    sortKey = .between(lastChildKey[parentIndex], nil)
                    lastChildKey[parentIndex] = sortKey
                } else {
                    sortKey = .between(lastRootKey, nil)
                    lastRootKey = sortKey
                }
                let page = Page(
                    title: SampleText.pageTitle(index, isLarge: index == pageCount - 1, largeBlockCount: shape.largePageBlockCount, random: &random),
                    icon: random.chance(0.3) ? SampleText.icons.randomElement(using: &random) : nil,
                    parentId: parentIndex.map { pageIds[$0] },
                    sortKey: sortKey,
                    createdAt: now,
                    updatedAt: now
                )
                try transaction.insertPage(page)
                pageIds.append(page.id)
            }

            for index in 0..<pageCount {
                let pageId = pageIds[index]
                var sortKey: FractionalSortKey?
                var listIndent = 0
                for _ in 0..<plan.contentBlockCounts[index] {
                    sortKey = .between(sortKey, nil)
                    let block = SampleText.contentBlock(pageId: pageId, sortKey: sortKey!, listIndent: &listIndent, random: &random)
                    try transaction.insertBlock(block)
                }
                for childIndex in plan.children[index] {
                    sortKey = .between(sortKey, nil)
                    try transaction.insertBlock(Block(pageId: pageId, kind: .pageLink, linkedPageId: pageIds[childIndex], sortKey: sortKey!))
                }
            }
            return pageIds[pageCount - 1]
        }
        // Условие замеров (research R13): при запуске открыта самая большая страница.
        try store.saveWindowState(WindowState(windowId: WindowState.mainWindowId, openPageId: largePageId))
    }
}

/// Форма дерева: родители, дети и число блоков текста у каждой страницы.
private struct TreePlan {
    var parents: [Int?] = []
    var children: [[Int]]
    var contentBlockCounts: [Int]

    init(shape: ReferenceLibraryGenerator.Shape, random: inout SeededRandom) {
        let pageCount = shape.pageCount
        let maxLevels = shape.maxLevels
        var levels: [Int] = []
        children = Array(repeating: [], count: pageCount)

        for index in 0..<pageCount {
            let parent: Int?
            if index < maxLevels {
                // Первые десять страниц — цепочка: глубина эталона ровно 10 уровней.
                parent = index == 0 ? nil : index - 1
            } else if index == pageCount - 1 || random.chance(0.08) {
                // Последняя страница — большая, в корне и без подстраниц.
                parent = nil
            } else {
                var candidate = Int.random(in: 0..<(pageCount - 1), using: &random) % index
                while levels[candidate] >= maxLevels { candidate = (candidate + 1) % index }
                parent = candidate
            }
            parents.append(parent)
            levels.append(parent.map { levels[$0] + 1 } ?? 1)
            if let parent { children[parent].append(index) }
        }

        let largePage = pageCount - 1
        let pageLinkCount = children.reduce(0) { $0 + $1.count }
        let regularContent = shape.blockCount - shape.largePageBlockCount - pageLinkCount
        let regularPages = pageCount - 1
        contentBlockCounts = (0..<pageCount).map { index in
            index == largePage
                ? shape.largePageBlockCount
                : regularContent / regularPages + (index < regularContent % regularPages ? 1 : 0)
        }
    }
}

/// Случайные, но повторяемые названия и текст на двух языках.
private enum SampleText {
    static let icons = ["📘", "📝", "📌", "💡", "🗂️", "🧭", "📎", "🌿", "🛠️", "🎯"]

    static let words = [
        "заметка", "проект", "встреча", "идея", "список", "задача", "страница", "неделя", "план", "черновик",
        "книга", "урок", "сервер", "дизайн", "привычка", "покупки", "отчёт", "вопрос", "ответ", "решение",
        "ёлка", "щука", "съёмка", "объявление", "Москва", "Бали", "MyNotion", "Swift", "release", "notes",
        "meeting", "draft", "roadmap", "sync", "backup", "invoice", "review", "launch", "idea", "focus",
        "SQLite", "TextKit", "keyboard", "outline", "weekly", "summary", "budget", "travel", "inbox", "archive",
    ]

    static func pageTitle(_ index: Int, isLarge: Bool, largeBlockCount: Int, random: inout SeededRandom) -> String {
        if isLarge { return largeBlockCount == 1_000 ? "Большая страница — 1 000 блоков" : "Большая страница — \(largeBlockCount) блоков" }
        let count = Int.random(in: 1...4, using: &random)
        let phrase = (0..<count).map { _ in words.randomElement(using: &random)! }.joined(separator: " ")
        return "\(phrase.prefix(1).uppercased())\(phrase.dropFirst()) \(index + 1)"
    }

    static func contentBlock(pageId: UUID, sortKey: FractionalSortKey, listIndent: inout Int, random: inout SeededRandom) -> Block {
        let roll = Double.random(in: 0..<1, using: &random)
        let kind: BlockKind = switch roll {
        case ..<0.48: .paragraph
        case ..<0.52: .heading1
        case ..<0.56: .heading2
        case ..<0.60: .heading3
        case ..<0.74: .bulletItem
        case ..<0.86: .numberedItem
        default: .checkbox
        }
        if kind == .bulletItem || kind == .numberedItem || kind == .checkbox {
            listIndent = max(0, min(listIndent + Int.random(in: -1...1, using: &random), 3))
        } else {
            listIndent = 0
        }
        let wordCount = kind.isHeading ? Int.random(in: 2...6, using: &random) : Int.random(in: 3...40, using: &random)
        return Block(
            pageId: pageId,
            kind: kind,
            text: text(wordCount: wordCount, random: &random),
            indent: kind.isHeading || kind == .paragraph ? 0 : listIndent,
            isChecked: kind == .checkbox && random.chance(0.4),
            sortKey: sortKey
        )
    }

    static func text(wordCount: Int, random: inout SeededRandom) -> InlineText {
        var string = ""
        var runs: [StyledRun] = []
        for position in 0..<wordCount {
            if position > 0 { string += " " }
            var word = words.randomElement(using: &random)!
            if position == 0 { word = word.prefix(1).uppercased() + word.dropFirst() }
            let start = (string as NSString).length
            string += word
            if random.chance(0.04) {
                let style: InlineStyle = [.bold, .italic, .strikethrough, .code, .link(URL(string: "https://example.com/\(word)")!)]
                    .randomElement(using: &random)!
                runs.append(StyledRun(start: start, length: (word as NSString).length, style: style))
            }
        }
        return InlineText(string + ".", runs: runs)
    }
}

/// Повторяемый генератор случайных чисел (SplitMix64).
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func chance(_ probability: Double) -> Bool {
        Double.random(in: 0..<1, using: &self) < probability
    }
}
