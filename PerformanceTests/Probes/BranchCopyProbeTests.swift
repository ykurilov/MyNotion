import AppKit
import NotesCore
import PageEditor
import XCTest

/// Проба копии ветки (T006, research R14, п. 4): 50 подстраниц, 5 000 блоков, 10 картинок — копия одной транзакцией
/// ≤ 2 с; главный поток не замирает дольше 100 мс (таймер на главном потоке каждые 16 мс); копия читается с тем же текстом.
/// Копия — настоящим `PageBranchCopier`. Запись идёт с очереди записи (research R7, запасной путь); для сравнения меряется
/// и запись прямо на главном потоке.
@MainActor
final class BranchCopyProbeTests: XCTestCase {
    static let copyBudgetSeconds = 2.0
    static let freezeBudgetMs = 100.0

    func testBranchCopyFitsBudgetWithoutFreezingMainThread() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotion-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try NotesStore(database: AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")),
                                   clock: HybridLogicalClock(deviceId: UUID()))
        let rootId = try Self.makeBranch(in: store)
        let original = try Self.texts(ofBranch: rootId, in: store)
        XCTAssertEqual(original.pageCount, 51)
        XCTAssertEqual(original.blockCount, 5_000 + 50, "Ветка: 5 000 блоков и 50 ссылок на подстраницы")

        // С очереди записи: главный поток остаётся отзывчивым.
        let watch = MainThreadWatch()
        watch.start()
        let started = ContinuousClock.now
        let copyId = try await Task.detached { try BranchCopyDraft.copy(rootId, in: store) }.value
        let backgroundSeconds = Self.seconds(ContinuousClock.now - started)
        watch.stop()
        let copied = try Self.texts(ofBranch: copyId, in: store)

        // Для сравнения — та же копия прямо на главном потоке (столько он и замер бы).
        let mainStarted = ContinuousClock.now
        _ = try BranchCopyDraft.copy(rootId, in: store)
        let mainSeconds = Self.seconds(ContinuousClock.now - mainStarted)

        let summary = """
            Проба копии ветки: 51 страница, \(original.blockCount) блоков, 10 картинок — с очереди записи \(String(format: "%.2f", backgroundSeconds)) с \
            (предел 2), главный поток замирал не дольше \(ProbeEditor.format(watch.maxGapMs)) мс (предел 100), тиков \(watch.ticks)
            Проба копии ветки: та же копия прямо на главном потоке — \(String(format: "%.2f", mainSeconds)) с
            Проба копии ветки: копия — \(copied.pageCount) страниц, \(copied.blockCount) блоков, текст совпал: \(copied.texts == original.texts ? "да" : "нет")
            """
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertLessThanOrEqual(backgroundSeconds, Self.copyBudgetSeconds, "Копия ветки дольше 2 с")
        XCTAssertLessThanOrEqual(watch.maxGapMs, Self.freezeBudgetMs, "Главный поток замирал дольше 100 мс")
        XCTAssertEqual(copied.pageCount, original.pageCount)
        XCTAssertEqual(copied.texts, original.texts, "Копия читается с другим текстом")
    }

    /// Корень, 10 детей по 4 внука — 50 подстраниц; у каждой подстраницы 100 блоков, у первых 10 — по картинке;
    /// у родителей — ссылки на детей.
    static func makeBranch(in store: NotesStore) throws -> UUID {
        let imageProps = try XCTUnwrap(BlockKinds.richPageParts.first { $0.name == BlockKind.image.rawValue }?.blocks.first?.props)
        return try store.write { tx in
            let root = try tx.createPage(title: "Ветка для копии")
            var subpage = 0
            func fill(_ page: Page, children: Int, depth: Int) throws {
                for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
                var key: FractionalSortKey?
                func add(_ block: (FractionalSortKey) -> Block) throws {
                    key = .between(key, nil)
                    _ = try tx.insertBlock(block(key!))
                }
                if page.id != root.id {
                    subpage += 1
                    let number = subpage
                    for index in 0..<100 {
                        if index == 50, number <= 10 {
                            try add { Block(pageId: page.id, kind: .image, sortKey: $0, props: imageProps) }
                        } else {
                            try add { Block(pageId: page.id, kind: index % 10 == 0 ? .heading2 : .paragraph,
                                            text: InlineText("Подстраница \(number), блок \(index + 1): текст для копии ветки."), sortKey: $0) }
                        }
                    }
                }
                guard depth < 2 else { return }
                for child in 0..<children {
                    let childPage = try tx.createPage(title: "Подстраница \(depth).\(child + 1)", parentId: page.id)
                    try add { Block(pageId: page.id, kind: .pageLink, linkedPageId: childPage.id, sortKey: $0) }
                    try fill(childPage, children: 4, depth: depth + 1)
                }
            }
            try fill(root, children: 10, depth: 0)
            return root.id
        }
    }

    /// Тексты ветки по пути названий (без id): копия должна читаться так же.
    static func texts(ofBranch rootId: UUID, in store: NotesStore) throws -> (pageCount: Int, blockCount: Int, texts: [String: [String]]) {
        let outline = try store.pageOutline()
        var result: [String: [String]] = [:]
        var blocks = 0, pages = 0
        func visit(_ id: UUID, path: String) throws {
            let content = try XCTUnwrap(try store.pageContent(id))
            pages += 1
            blocks += content.blocks.count
            result[path] = content.blocks.map { "\($0.kind.rawValue):\($0.text.string)" }
            for child in outline.filter({ $0.parentId == id }) { try visit(child.id, path: path + "/" + child.title) }
        }
        try visit(rootId, path: "")
        return (pages, blocks, result)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// Копия ветки для проб: настоящий `PageBranchCopier` (T019) одной транзакцией, копия — сразу под оригиналом.
enum BranchCopyDraft {
    static func copy(_ rootId: UUID, in store: NotesStore) throws -> UUID {
        try store.write { tx in
            guard let root = try tx.page(rootId) else { throw NotesStoreError.pageNotFound(rootId) }
            return try PageBranchCopier.copy(rootId, in: tx, title: root.title + " (1)", parentId: root.parentId,
                                             sortKey: .between(root.sortKey, nil)).rootId
        }
    }
}

/// Таймер на главном потоке каждые 16 мс: самый долгий промежуток между тиками — сколько главный поток не отвечал.
@MainActor
final class MainThreadWatch {
    private var timer: Timer?
    private var last = ContinuousClock.now
    private(set) var maxGapMs = 0.0
    private(set) var ticks = 0

    func start() {
        last = .now
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = ContinuousClock.now
        let gap = now - last
        maxGapMs = max(maxGapMs, Double(gap.components.seconds) * 1_000 + Double(gap.components.attoseconds) / 1e15)
        last = now
        ticks += 1
    }

    func stop() {
        tick()
        timer?.invalidate()
    }
}
