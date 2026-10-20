import AppKit
import NotesCore
import PageEditor
import XCTest

/// Страница в настоящем `PageTextView` в видимом окне — для проб TextKit 2 этапа 0 (research R16).
/// Нажатие меряется, как в `TypingBenchmark`: от отправки события окну до конца перерисовки окна.
@MainActor
final class ProbeEditor {
    struct Spec {
        var kind: BlockKind = .paragraph
        var text: String
        var indent = 0
        var props: BlockProps = .empty
    }

    let folder: URL
    let document: PageDocument
    let textView: PageTextView
    let window: NSWindow

    init(_ specs: [Spec]) throws {
        _ = NSApplication.shared
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotion-probe-\(UUID().uuidString)", isDirectory: true)
        let store = try NotesStore(database: AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")),
                                   clock: HybridLogicalClock(deviceId: UUID()))
        let pageId = try store.write { tx in
            let page = try tx.createPage(title: "Проба")
            for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            for spec in specs {
                key = .between(key, nil)
                try tx.insertBlock(Block(pageId: page.id, kind: spec.kind, text: InlineText(spec.text), indent: spec.indent, sortKey: key!,
                                         props: spec.props))
            }
            return page.id
        }
        document = PageDocument(content: try XCTUnwrap(try store.pageContent(pageId)))
        // Без начального фокуса: страница, показанная в окне, сама ставит курсор в начало чуть позже,
        // и набор пробы ушёл бы в первый абзац.
        textView = PageTextView(document: document, initialFocus: .unchanged)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        textView.frame.size.width = 1200
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        window.displayIfNeeded()
    }

    /// Дать окну закончить показ страницы: отложенная раскладка и фокус.
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
        window.displayIfNeeded()
    }

    func close() {
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Начало абзаца блока `index`.
    func location(ofBlock index: Int) -> Int {
        let string = textView.string as NSString
        var location = 0
        for _ in 0..<index { location = NSMaxRange(string.paragraphRange(for: NSRange(location: location, length: 0))) }
        return location
    }

    func placeCaret(_ location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        window.displayIfNeeded()
    }

    /// Набрать `count` букв; `afterEach` — работа, которая в приложении идёт на каждую правку.
    /// Буква вставляется тем же `insertText`, что вызывает нажатие: в процессе тестов без приложения событие клавиши
    /// идёт через службу ввода, которой нет, и после первой буквы нажатия теряются (проба 19.10.2026).
    func type(_ count: Int, afterEach: () -> Void = {}) async throws -> [Double] {
        let characters = Array("быстрый набор text ")
        var samples: [Double] = []
        for index in 0..<count {
            let character = String(characters[index % characters.count])
            samples.append(Self.measure {
                textView.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
                afterEach()
                window.displayIfNeeded()
            })
            try await Task.sleep(for: .milliseconds(10))
        }
        return samples
    }

    static func measure(_ action: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try action()
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    /// Время процессора потока, мс: почти не зависит от нагрузки остальных программ (основной Mac бывает занят,
    /// виртуальный Mac делит с ним процессор) — по нему сравниваются правки.
    static func measureCPU(_ action: () throws -> Void) rethrows -> (wall: Double, cpu: Double) {
        let cpuStart = threadCPUMilliseconds()
        let wall = try measure(action)
        return (wall, threadCPUMilliseconds() - cpuStart)
    }

    static func threadCPUMilliseconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) * 1_000 + Double(time.tv_nsec) / 1e6
    }

    static func median(_ samples: [Double]) -> Double { samples.isEmpty ? 0 : samples.sorted()[samples.count / 2] }

    static func p95(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted[min(max(Int((Double(sorted.count) * 0.95).rounded(.up)) - 1, 0), sorted.count - 1)]
    }

    static func format(_ value: Double) -> String { String(format: "%.1f", value) }
}
