import AppKit
import NotesCore
import PageEditor
import XCTest

/// Утечка при переходе между «богатыми» страницами (research R15, п. 2): 200 переходов — занятое в куче не растёт больше
/// чем на 5 МБ. Переход — как в окне: новый редактор на странице вместо прежнего. При росте — снимки кучи (`heap`)
/// до и после: какие объекты копятся, пишется в `~/probe-shots/heap-*.txt` и строками «Проба утечки».
@MainActor
final class RichPageLeakProbeTests: XCTestCase {
    static let switchCount = 100
    static let memoryBudgetMB = 5.0

    func testRichPageSwitchesDoNotLeak() throws {
        let page = try RichProbePage()
        defer { page.close() }
        let other = try BranchCopyDraft.copy(page.pageId, in: page.store)
        let pages = [page.pageId, other]
        // Переход и следующие ходы цикла событий — в одном пуле автоосвобождения, как ход цикла событий в окне.
        // Без этого XCTest держит всё автоосвобождённое за время пробы (проверено `leaks --traceTree` 20.10.2026:
        // старые хранилища текста держал только пул тестового процесса).
        func switchTo(_ index: Int) throws {
            try autoreleasepool {
                page.show(try RichProbePage.editor(for: pages[index % 2], in: page.store))
                page.window.displayIfNeeded()
                page.scroll(toBlock: 300 + index % 7 * 80)
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }
        func settle() {
            for _ in 0..<5 { autoreleasepool { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) } }
        }
        for index in 0..<10 { try switchTo(index) }
        settle()
        let before = RichProbePage.footprintMB()
        let heapBeforeMB = RichProbePage.heapAllocatedMB()
        let heapBefore = Self.heapCounts()
        let vmBefore = Self.run("/usr/bin/vmmap", ["--summary", "\(ProcessInfo.processInfo.processIdentifier)"])
        var checkpoints: [String] = []
        for index in 0..<Self.switchCount * 2 {
            try switchTo(index)
            if (index + 1) % 50 == 0 {
                settle()
                checkpoints.append("\(index + 1): \(ProbeEditor.format(RichProbePage.footprintMB()))")
            }
        }
        print("Проба утечки: след памяти по ходу — до \(ProbeEditor.format(before)), " + checkpoints.joined(separator: ", ") + " МБ")
        let vmAfter = Self.run("/usr/bin/vmmap", ["--summary", "\(ProcessInfo.processInfo.processIdentifier)"])
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("probe-shots", isDirectory: true)
        try? (vmBefore + "\n\n===== ПОСЛЕ =====\n\n" + vmAfter).write(to: folder.appendingPathComponent("vmmap.txt"), atomically: true, encoding: .utf8)
        let after = RichProbePage.footprintMB()
        let heapAfterMB = RichProbePage.heapAllocatedMB()
        let heapAfter = Self.heapCounts()
        if heapAfterMB - heapBeforeMB > Self.memoryBudgetMB { Self.saveLeaksReport() }

        var growth: [(name: String, count: Int, bytes: Int)] = []
        for (name, value) in heapAfter {
            let old = heapBefore[name] ?? (0, 0)
            if value.bytes - old.bytes > 64 * 1024 { growth.append((name, value.count - old.count, value.bytes - old.bytes)) }
        }
        growth.sort { $0.bytes > $1.bytes }
        let lines = growth.prefix(12).map { "Проба утечки: \($0.name) +\($0.count) шт., +\($0.bytes / 1024) КБ" }
        let summary = (["Проба утечки: \(Self.switchCount * 2) переходов между «богатыми» страницами — занято в куче \(ProbeEditor.format(heapBeforeMB)) → \(ProbeEditor.format(heapAfterMB)) МБ (прирост \(ProbeEditor.format(heapAfterMB - heapBeforeMB)), предел 5), след памяти \(ProbeEditor.format(before)) → \(ProbeEditor.format(after)) МБ; живых редакторов \(PageTextView.liveEditorCount)"] + lines).joined(separator: "\n")
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertLessThanOrEqual(heapAfterMB - heapBeforeMB, Self.memoryBudgetMB, "Переходы между «богатыми» страницами копят память")
    }

    /// Отчёт `leaks` (круги ссылок, недостижимые из корней) — `~/probe-shots/leaks.txt`.
    static func saveLeaksReport() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("probe-shots", isDirectory: true)
        try? data.write(to: folder.appendingPathComponent("leaks.txt"))
        // Кто держит старые тексты: путь ссылок от корня до нескольких хранилищ текста и вложений.
        saveTraceTrees(of: ["NSTextContentStorage", "NSTextLayoutManager", "BlockAttachment"], to: "trace-tree.txt")
    }

    /// Пути ссылок от корней до двух экземпляров каждого класса — `~/probe-shots/<file>`.
    static func saveTraceTrees(of classes: [String], to file: String) {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("probe-shots", isDirectory: true)
        var trees = ""
        for className in classes {
            let addresses = run("/usr/bin/heap", ["\(ProcessInfo.processInfo.processIdentifier)", "-addresses=\(className)"])
                .split(separator: "\n").compactMap { line -> String? in
                    guard let range = line.range(of: "0x") else { return nil }
                    return String(line[range.lowerBound...].prefix { !$0.isWhitespace && $0 != ":" })
                }
            trees += "== \(className): \(addresses.count) шт.\n"
            for address in addresses.prefix(2) {
                trees += run("/usr/bin/leaks", ["\(ProcessInfo.processInfo.processIdentifier)", "--traceTree=\(address)"]) + "\n"
            }
        }
        try? trees.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Снимок кучи своего процесса: имя класса → (штук, байт).
    static func heapCounts() -> [String: (count: Int, bytes: Int)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/heap")
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("probe-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? text.write(to: folder.appendingPathComponent("heap-\(Int(Date().timeIntervalSince1970)).txt"), atomically: true, encoding: .utf8)
        var result: [String: (Int, Int)] = [:]
        // Строки таблицы: «COUNT  BYTES  AVG  CLASS_NAME  TYPE  BINARY».
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, let count = Int(fields[0]), let bytes = Int(fields[1]), Double(fields[2]) != nil else { continue }
            let name = fields[3...].joined(separator: " ")
            let old = result[name] ?? (0, 0)
            result[name] = (old.0 + count, old.1 + bytes)
        }
        return result
    }
}
