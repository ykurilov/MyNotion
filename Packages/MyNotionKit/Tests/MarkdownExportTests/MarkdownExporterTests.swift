import Foundation
import Synchronization
import Testing
import NotesCore
@testable import MarkdownExport

/// Выгрузка всех записей в папку Markdown (FR-017, contracts/files-import-export.md).
@Suite("Выгрузка в Markdown")
struct MarkdownExporterTests {
    private let workFolder: URL
    private let store: NotesStore
    private let exportDate: Date

    init() throws {
        workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotionExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let database = try AppDatabase.open(at: workFolder.appendingPathComponent("MyNotion.sqlite"))
        store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: UUID()))
        exportDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 15))!
    }

    private var destination: URL { workFolder.appendingPathComponent("Выгрузки", isDirectory: true) }
    private var exportFolder: URL { destination.appendingPathComponent("MyNotion-выгрузка-2026-10-18", isDirectory: true) }

    private func makeDestination() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    private func exporter(writeFile: (@Sendable (Data, URL) throws -> Void)? = nil) -> MarkdownExporter {
        var exporter = MarkdownExporter(store: store, now: { [exportDate] in exportDate })
        if let writeFile { exporter.writeFile = writeFile }
        return exporter
    }

    @discardableResult
    private func runExport(progress: (@Sendable (MarkdownExportProgress) -> Void)? = nil) throws -> MarkdownExportResult {
        try makeDestination()
        return try exporter().export(into: destination, progress: progress)
    }

    /// Все файлы и папки выгрузки относительными путями, по алфавиту.
    private func exportedPaths() throws -> [String] {
        // Временная папка лежит за ссылкой /var → /private/var: сравниваем пути после её раскрытия.
        let root = exportFolder.resolvingSymlinksInPath()
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])!
        var paths: [String] = []
        for case let url as URL in enumerator {
            let isDirectory = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            paths.append(isDirectory ? relative + "/" : relative)
        }
        return paths.sorted()
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: exportFolder.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func addBlocks(_ page: Page, _ blocks: [(BlockKind, String)]) throws {
        try store.write { tx in
            var key = try tx.blocks(ofPage: page.id).last?.sortKey
            for (kind, text) in blocks {
                key = .between(key, nil)
                try tx.insertBlock(Block(pageId: page.id, kind: kind, text: InlineText(text), sortKey: key!))
            }
            // Пустой абзац, который создаётся вместе со страницей, мешает счёту блоков.
            if let first = try tx.blocks(ofPage: page.id).first, first.kind == .paragraph, first.text.string.isEmpty, !blocks.isEmpty {
                try tx.deleteBlock(first.id)
            }
        }
    }

    // MARK: Папки и файлы

    @Test("Папка называется MyNotion-выгрузка-<дата>, страницы и подстраницы лежат как в контракте")
    func treeLayout() throws {
        let (projects, myNotion, _, diary) = try store.write { tx -> (Page, Page, Page, Page) in
            let projects = try tx.createPage(title: "Проекты")
            let myNotion = try tx.createPage(title: "MyNotion", parentId: projects.id)
            let ideas = try tx.createPage(title: "Идеи", parentId: myNotion.id)
            let diary = try tx.createPage(title: "Дневник")
            return (projects, myNotion, ideas, diary)
        }
        _ = (projects, myNotion, diary)

        let result = try runExport()

        #expect(result.folder.lastPathComponent == "MyNotion-выгрузка-2026-10-18")
        #expect(try exportedPaths() == [
            "Дневник.md",
            "Проекты.md",
            "Проекты/",
            "Проекты/MyNotion.md",
            "Проекты/MyNotion/",
            "Проекты/MyNotion/Идеи.md",
        ])
    }

    @Test("Страница без подстраниц не получает пустую папку")
    func noEmptyFolders() throws {
        try store.write { try $0.createPage(title: "Одна") }
        try runExport()
        #expect(try exportedPaths() == ["Одна.md"])
    }

    @Test("Первая строка файла — название, перед названием иконка страницы")
    func titleLineWithIcon() throws {
        let page = try store.write { try $0.createPage(title: "Проекты", icon: "📘") }
        try addBlocks(page, [(.paragraph, "Текст")])
        try store.write { try $0.createPage(title: "Без иконки") }
        try store.write { try $0.createPage(title: "") }

        try runExport()

        #expect(try read("Проекты.md") == "# 📘 Проекты\n\nТекст\n")
        #expect(try read("Без иконки.md").hasPrefix("# Без иконки\n"))
        #expect(try read("Без названия.md").hasPrefix("# Без названия\n"))
    }

    @Test("Название страницы с Markdown-знаками экранируется в первой строке")
    func titleLineEscaping() throws {
        try store.write { try $0.createPage(title: "2 * 3 [черновик]") }
        try runExport()
        #expect(try read("2 * 3 [черновик].md").hasPrefix("# 2 \\* 3 \\[черновик\\]\n"))
    }

    @Test("Все блоки страницы попадают в файл по порядку, пустая страница — только название")
    func pageBody() throws {
        let page = try store.write { try $0.createPage(title: "Всё сразу") }
        try addBlocks(page, [
            (.heading1, "Заголовок"), (.paragraph, "Абзац"), (.bulletItem, "пункт"), (.numberedItem, "первый"),
            (.numberedItem, "второй"), (.checkbox, "задача"),
        ])
        try store.write { try $0.createPage(title: "Пустая") }

        try runExport()

        #expect(try read("Всё сразу.md") == """
            # Всё сразу

            # Заголовок

            Абзац

            - пункт

            1. первый
            2. второй

            - [ ] задача

            """)
        #expect(try read("Пустая.md") == "# Пустая\n")
    }

    @Test("Ссылки на подстраницы ведут на файлы относительными путями")
    func pageLinks() throws {
        let (projects, myNotion, ideas, diary) = try store.write { tx -> (Page, Page, Page, Page) in
            let projects = try tx.createPage(title: "Проекты")
            let myNotion = try tx.createPage(title: "MyNotion", parentId: projects.id)
            let ideas = try tx.createPage(title: "Идеи", parentId: myNotion.id)
            let diary = try tx.createPage(title: "Дневник")
            return (projects, myNotion, ideas, diary)
        }
        try store.write { tx in
            try tx.insertBlock(Block(pageId: projects.id, kind: .pageLink, linkedPageId: myNotion.id, sortKey: .between(nil, nil)))
            try tx.insertBlock(Block(pageId: myNotion.id, kind: .pageLink, linkedPageId: ideas.id, sortKey: .between(nil, nil)))
            // Ссылка в другую ветку: вверх и в сторону.
            try tx.insertBlock(Block(pageId: ideas.id, kind: .pageLink, linkedPageId: diary.id, sortKey: .between(nil, nil)))
            try tx.insertBlock(Block(pageId: ideas.id, kind: .pageLink, linkedPageId: projects.id, sortKey: .between(.between(nil, nil), nil)))
        }

        try runExport()

        #expect(try read("Проекты.md").contains("[MyNotion](Проекты/MyNotion.md)"))
        #expect(try read("Проекты/MyNotion.md").contains("[Идеи](MyNotion/Идеи.md)"))
        #expect(try read("Проекты/MyNotion/Идеи.md").contains("[Дневник](../../Дневник.md)"))
        #expect(try read("Проекты/MyNotion/Идеи.md").contains("[Проекты](../../Проекты.md)"))
    }

    @Test("Подстраница из «/» выгружается ссылкой на своём месте среди абзацев")
    @MainActor
    func inlineSubpageLink() throws {
        let (projects, middle) = try store.write { tx -> (Page, Block) in
            let projects = try tx.createPage(title: "Проекты")
            var first = try #require(try tx.blocks(ofPage: projects.id).first)
            first.text = InlineText("до")
            try tx.updateBlock(first)
            let middle = try tx.insertBlock(Block(pageId: projects.id, sortKey: .between(first.sortKey, nil)))
            try tx.insertBlock(Block(pageId: projects.id, text: InlineText("после"), sortKey: .between(middle.sortKey, nil)))
            return (projects, middle)
        }
        try PageTreeOperations(store: store).createSubpage(in: projects.id, title: "План", linkAt: .replacing(blockId: middle.id))

        try runExport()

        let text = try read("Проекты.md")
        let link = try #require(text.range(of: "[План](Проекты/План.md)"))
        #expect(try #require(text.range(of: "до")).upperBound < link.lowerBound)
        #expect(link.upperBound < (try #require(text.range(of: "после"))).lowerBound)
        #expect(FileManager.default.fileExists(atPath: exportFolder.appendingPathComponent("Проекты/План.md").path))
    }

    // MARK: Имена

    @Test("Слэш и двоеточие в названии заменяются на дефис")
    func forbiddenCharacters() throws {
        try store.write { try $0.createPage(title: "Идея: 1/2") }
        try runExport()
        #expect(try exportedPaths() == ["Идея- 1-2.md"])
        #expect(try read("Идея- 1-2.md").hasPrefix("# Идея: 1/2\n"))
    }

    @Test("Одинаковые названия соседей получают (2), (3)")
    func duplicateSiblings() throws {
        try store.write { tx in
            for _ in 0..<3 { try tx.createPage(title: "Идеи") }
        }
        try runExport()
        #expect(try exportedPaths() == ["Идеи (2).md", "Идеи (3).md", "Идеи.md"])
    }

    @Test("Названия, различающиеся только регистром, — тоже одинаковые: папка Mac не различает регистр")
    func caseInsensitiveDuplicates() throws {
        try store.write { tx in
            try tx.createPage(title: "Идеи")
            try tx.createPage(title: "ИДЕИ")
        }
        try runExport()
        #expect(try exportedPaths() == ["ИДЕИ (2).md", "Идеи.md"])
    }

    @Test("Одинаковые названия в разных ветках не мешают друг другу")
    func sameNamesInDifferentBranches() throws {
        try store.write { tx in
            let a = try tx.createPage(title: "A")
            let b = try tx.createPage(title: "B")
            try tx.createPage(title: "Идеи", parentId: a.id)
            try tx.createPage(title: "Идеи", parentId: b.id)
        }
        try runExport()
        #expect(try exportedPaths() == ["A.md", "A/", "A/Идеи.md", "B.md", "B/", "B/Идеи.md"])
    }

    @Test("Пустое название — «Без названия», точка в начале не прячет файл")
    func emptyAndHiddenNames() throws {
        try store.write { tx in
            try tx.createPage(title: "")
            try tx.createPage(title: "")
            try tx.createPage(title: ".скрытая")
        }
        try runExport()
        let paths = try exportedPaths()
        #expect(paths.contains("Без названия.md") && paths.contains("Без названия (2).md"))
        #expect(paths.allSatisfy { !$0.hasPrefix(".") })
    }

    @Test("Очень длинное название укорачивается до допустимой длины имени файла")
    func longNames() throws {
        let title = String(repeating: "Длинное название ", count: 30)
        try store.write { try $0.createPage(title: title) }
        try runExport()
        let name = try #require(try exportedPaths().first)
        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix(".md"))
    }

    // MARK: Корзина

    @Test("Страницы в корзине не выгружаются, подстраницы корзины — тоже")
    func trashIsNotExported() throws {
        let (kept, trashed, nested) = try store.write { tx -> (Page, Page, Page) in
            let kept = try tx.createPage(title: "Остаётся")
            let trashed = try tx.createPage(title: "Удалённая")
            let nested = try tx.createPage(title: "Вложенная", parentId: trashed.id)
            return (kept, trashed, nested)
        }
        _ = (kept, nested)
        try store.write { tx in
            var page = try #require(try tx.page(trashed.id))
            page.trashedAt = Date()
            try tx.updatePage(page)
        }

        let result = try runExport()

        #expect(try exportedPaths() == ["Остаётся.md"])
        #expect(result.pageCount == 1)
    }

    @Test("Ссылка на страницу из корзины — просто название")
    func linkToTrashedPage() throws {
        let (kept, trashed) = try store.write { tx -> (Page, Page) in
            (try tx.createPage(title: "Остаётся"), try tx.createPage(title: "Удалённая"))
        }
        try store.write { tx in
            try tx.insertBlock(Block(pageId: kept.id, kind: .pageLink, linkedPageId: trashed.id, sortKey: .between(.between(nil, nil), nil)))
            var page = try #require(try tx.page(trashed.id))
            page.trashedAt = Date()
            try tx.updatePage(page)
        }

        try runExport()

        let text = try read("Остаётся.md")
        #expect(text.contains("Удалённая"))
        #expect(!text.contains("](") && !text.contains(".md"))
    }

    // MARK: Итог

    @Test("Итог: число страниц и блоков, папка выгрузки")
    func result() throws {
        let page = try store.write { try $0.createPage(title: "Страница") }
        try addBlocks(page, [(.paragraph, "a"), (.paragraph, "b"), (.paragraph, "c")])
        try store.write { try $0.createPage(title: "Вторая") }

        let result = try runExport()

        #expect(result.pageCount == 2)
        // Три блока и один пустой абзац второй страницы.
        #expect(result.blockCount == 4)
        #expect(result.folder.standardizedFileURL == exportFolder.standardizedFileURL)
    }

    @Test("Пустая база выгружается в пустую папку")
    func emptyLibrary() throws {
        let result = try runExport()
        #expect(result.pageCount == 0)
        #expect(try exportedPaths().isEmpty)
    }

    @Test("Ход работы: число готовых страниц растёт до общего числа")
    func progress() throws {
        try store.write { tx in
            for index in 0..<5 { try tx.createPage(title: "Страница \(index)") }
        }
        let reported = Mutex<[MarkdownExportProgress]>([])

        try runExport { step in reported.withLock { $0.append(step) } }

        let steps = reported.withLock { $0 }
        #expect(steps.last?.pagesDone == 5)
        #expect(steps.allSatisfy { $0.pagesTotal == 5 })
        #expect(steps.map(\.pagesDone) == steps.map(\.pagesDone).sorted())
    }

    // MARK: Безопасность записи

    @Test("Второй раз в тот же день — рядом новая папка, прежняя не тронута")
    func secondExportSameDay() throws {
        try store.write { try $0.createPage(title: "Страница") }
        try runExport()
        let first = try read("Страница.md")
        let marker = exportFolder.appendingPathComponent("Моя заметка.txt")
        try "не трогать".write(to: marker, atomically: true, encoding: .utf8)

        let second = try runExport()

        #expect(second.folder.lastPathComponent == "MyNotion-выгрузка-2026-10-18 (2)")
        #expect(try String(contentsOf: marker, encoding: .utf8) == "не трогать")
        #expect(try read("Страница.md") == first)
    }

    @Test("Ошибка записи посреди выгрузки: понятное сообщение, ни папки выгрузки, ни временной папки")
    func failureLeavesNothing() throws {
        try store.write { tx in
            for index in 0..<5 { try tx.createPage(title: "Страница \(index)") }
        }
        try makeDestination()
        let written = Mutex(0)
        let failing = exporter { data, url in
            let count = written.withLock { value -> Int in value += 1; return value }
            if count == 3 { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url)
        }

        let error = #expect(throws: MarkdownExportError.self) {
            try failing.export(into: destination, progress: nil)
        }

        #expect(error?.errorDescription?.isEmpty == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test("Нет папки для выгрузки — понятная ошибка, ничего не создано")
    func missingDestination() throws {
        try store.write { try $0.createPage(title: "Страница") }
        let missing = workFolder.appendingPathComponent("нет такой папки", isDirectory: true)

        let error = #expect(throws: MarkdownExportError.self) {
            try exporter().export(into: missing, progress: nil)
        }

        #expect(error?.errorDescription?.contains("нет такой папки") == true)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("Отмена посреди выгрузки: CancellationError и никаких следов")
    func cancellationLeavesNothing() async throws {
        try store.write { tx in
            for index in 0..<20 { try tx.createPage(title: "Страница \(index)") }
        }
        try makeDestination()
        let exporter = exporter()
        let destination = destination
        let task = Task.detached {
            try exporter.export(into: destination, progress: { step in
                if step.pagesDone == 3 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }

        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    // MARK: Эталонная база

    @Test("Эталонная база: все 1 000 страниц, все ссылки между файлами ведут на существующие файлы")
    func referenceLibrary() throws {
        try ReferenceLibraryGenerator().generate(into: store)

        let started = ContinuousClock.now
        let result = try runExport()
        let elapsed = ContinuousClock.now - started
        print("Выгрузка эталонной базы: \(elapsed)")

        #expect(result.pageCount == ReferenceLibraryGenerator.pageCount)
        #expect(result.blockCount >= ReferenceLibraryGenerator.blockCount)
        // 100 000 блоков: в быстрой сборке около 10 с, в тестовой (без оптимизаций) втрое дольше.
        #expect(elapsed < .seconds(60))

        let root = exportFolder
        var files = 0
        var brokenLinks: [String] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator where url.pathExtension == "md" {
            files += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where line.hasPrefix("[") && line.hasSuffix(".md)") {
                guard let open = line.range(of: "](", options: .backwards) else { continue }
                let encoded = String(line[open.upperBound...].dropLast())
                let path = encoded.removingPercentEncoding ?? encoded
                let target = url.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
                if !FileManager.default.fileExists(atPath: target.path) { brokenLinks.append("\(url.lastPathComponent) → \(path)") }
            }
        }
        #expect(files == ReferenceLibraryGenerator.pageCount)
        #expect(brokenLinks.isEmpty, "Битые ссылки: \(brokenLinks.prefix(5))")
    }
}
