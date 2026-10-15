import AppKit
import NotesCore
import os
import PageEditor

/// Замер отклика (T048, research R13): по флагу `--typing-benchmark <путь>` приложение само печатает
/// в открытой странице на 1 000 блоков, переходит между страницами, печатает и листает страницу
/// на 10 000 блоков, пишет время каждого действия и p95 в файл и выходит.
/// Каждое действие — интервал signpost (`Keystroke`, `PageSwitch`, `Scroll`) для Instruments.
/// Нажатие считается от отправки события окну до конца перерисовки окна.
@MainActor
enum TypingBenchmark {
    static let hugePageTitle = "Замер: страница на 10 000 блоков"
    static let hugePageBlockCount = 10_000
    static let keystrokes = 200
    static let pageSwitches = 30
    static let hugePageKeystrokes = 100
    static let scrollSteps = 60
    /// Пауза между нажатиями: человек быстро печатает примерно так.
    static let pauseBetweenActions: Duration = .milliseconds(10)

    private static let signposter = OSSignposter(subsystem: "cloud.kurilov.mynotion", category: .pointsOfInterest)
    private static let typedCharacters = Array("быстрый набор text ")
    private static var hasStarted = false
    private static var readyWaiter: CheckedContinuation<Bool, Never>?

    struct Report: Encodable {
        var typingMs: [Double] = []
        var pageSwitchMs: [Double] = []
        var hugePageOpenMs: Double?
        var hugePageTypingMs: [Double] = []
        var hugePageScrollMs: [Double] = []
        var typingP95Ms: Double?
        var pageSwitchP95Ms: Double?
        var hugePageTypingP95Ms: Double?
        var hugePageScrollP95Ms: Double?
        var error: String?

        mutating func summarize() {
            typingP95Ms = TypingBenchmark.p95(typingMs)
            pageSwitchP95Ms = TypingBenchmark.p95(pageSwitchMs)
            hugePageTypingP95Ms = TypingBenchmark.p95(hugePageTypingMs)
            hugePageScrollP95Ms = TypingBenchmark.p95(hugePageScrollMs)
        }

        func write(to url: URL) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(self).write(to: url, options: .atomic)
        }
    }

    struct BenchmarkFailure: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: Подготовка базы

    /// Страница на 10 000 блоков в базе замера: создаётся один раз, в корне после остальных.
    static func ensureHugePage(in store: NotesStore) throws {
        let outline = try store.pageOutline()
        guard !outline.contains(where: { $0.title == hugePageTitle && $0.trashedAt == nil }) else { return }
        let lastRootKey = outline.filter { $0.parentId == nil }.map(\.sortKey).max()
        try store.write { transaction in
            let now = Date()
            let page = Page(title: hugePageTitle, sortKey: .between(lastRootKey, nil), createdAt: now, updatedAt: now)
            try transaction.insertPage(page)
            var sortKey: FractionalSortKey?
            for index in 0..<hugePageBlockCount {
                sortKey = .between(sortKey, nil)
                let kind: BlockKind = switch index % 10 {
                case 0: .heading2
                case 1, 2, 3: .bulletItem
                case 4: .checkbox
                default: .paragraph
                }
                let text = InlineText("Блок \(index + 1): обычный текст страницы для замера, mixed with Latin words.")
                _ = try transaction.insertBlock(Block(pageId: page.id, kind: kind, text: text, sortKey: sortKey!))
            }
        }
    }

    // MARK: Ход замера

    /// Начать после первой готовности окна. Повторные вызовы — готовность после перехода на страницу.
    static func editorReady(model: MainWindowModel, reportTo url: URL) {
        if let waiter = readyWaiter {
            readyWaiter = nil
            waiter.resume(returning: true)
            return
        }
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            var report = Report()
            do {
                report = try await run(model)
            } catch {
                report.error = String(describing: error)
            }
            report.summarize()
            report.write(to: url)
            NSApp.terminate(nil)
        }
    }

    private static func run(_ model: MainWindowModel) async throws -> Report {
        var report = Report()
        try await Task.sleep(for: .milliseconds(500))

        let startPage = try openTextView()
        report.typingMs = try await type(keystrokes, in: startPage)

        let hugePageId = model.pages.first { $0.title == hugePageTitle }?.id
        let candidates = model.pages.map(\.id).filter { $0 != hugePageId && $0 != model.openPageId }
        guard candidates.count >= pageSwitches else { throw BenchmarkFailure(description: "В базе мало страниц для переходов") }
        let stride = candidates.count / pageSwitches
        for index in 0..<pageSwitches {
            report.pageSwitchMs.append(try await switchPage(to: candidates[index * stride], model: model))
            try await Task.sleep(for: pauseBetweenActions)
        }

        guard let hugePageId else { throw BenchmarkFailure(description: "Нет страницы на 10 000 блоков") }
        report.hugePageOpenMs = try await switchPage(to: hugePageId, model: model)
        let hugePage = try openTextView()
        report.hugePageScrollMs = try await scroll(hugePage, steps: scrollSteps)
        report.hugePageTypingMs = try await type(hugePageKeystrokes, in: hugePage)
        return report
    }

    /// Текст открытой страницы с курсором в конце абзаца посередине страницы.
    private static func openTextView() throws -> PageTextView {
        guard let window = NSApp.windows.first(where: { $0.firstResponder is PageTextView }),
              let textView = window.firstResponder as? PageTextView else {
            throw BenchmarkFailure(description: "Текст страницы не в фокусе")
        }
        let string = textView.string as NSString
        let paragraph = string.paragraphRange(for: NSRange(location: string.length / 2, length: 0))
        let end = NSMaxRange(paragraph) > paragraph.location && NSMaxRange(paragraph) <= string.length
            && string.character(at: NSMaxRange(paragraph) - 1) == 0x0A ? NSMaxRange(paragraph) - 1 : NSMaxRange(paragraph)
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        window.displayIfNeeded()
        return textView
    }

    private static func type(_ count: Int, in textView: PageTextView) async throws -> [Double] {
        guard let window = textView.window else { throw BenchmarkFailure(description: "Страница вне окна") }
        let lengthBefore = (textView.string as NSString).length
        var samples: [Double] = []
        for index in 0..<count {
            let character = String(typedCharacters[index % typedCharacters.count])
            guard let keyDown = keyEvent(.keyDown, character, window: window),
                  let keyUp = keyEvent(.keyUp, character, window: window) else {
                throw BenchmarkFailure(description: "Не удалось создать событие клавиши")
            }
            samples.append(measure("Keystroke") {
                window.sendEvent(keyDown)
                window.displayIfNeeded()
            })
            window.sendEvent(keyUp)
            try await Task.sleep(for: pauseBetweenActions)
        }
        guard (textView.string as NSString).length == lengthBefore + count else {
            throw BenchmarkFailure(description: "Нажатия не дошли до текста страницы")
        }
        return samples
    }

    /// От выбора страницы до готовности её редактора к вводу и перерисовки окна.
    private static func switchPage(to pageId: UUID, model: MainWindowModel) async throws -> Double {
        let state = signposter.beginInterval("PageSwitch")
        let start = ContinuousClock.now
        let ready = await withCheckedContinuation { continuation in
            readyWaiter = continuation
            model.select(pageId)
            Task {
                try? await Task.sleep(for: .seconds(10))
                if let waiter = readyWaiter {
                    readyWaiter = nil
                    waiter.resume(returning: false)
                }
            }
        }
        NSApp.windows.forEach { $0.displayIfNeeded() }
        let elapsed = milliseconds(ContinuousClock.now - start)
        signposter.endInterval("PageSwitch", state)
        guard ready else { throw BenchmarkFailure(description: "Страница не открылась за 10 с") }
        return elapsed
    }

    /// Прокрутка на высоту окна вниз до конца и обратно.
    private static func scroll(_ textView: PageTextView, steps: Int) async throws -> [Double] {
        guard let scrollView = textView.enclosingScrollView, let window = textView.window else {
            throw BenchmarkFailure(description: "У страницы нет прокрутки")
        }
        let clipView = scrollView.contentView
        let step = clipView.bounds.height
        var samples: [Double] = []
        var direction: CGFloat = 1
        for _ in 0..<steps {
            let maxY = max(0, textView.frame.height - clipView.bounds.height)
            var y = clipView.bounds.origin.y + direction * step
            if y > maxY || y < 0 {
                direction = -direction
                y = min(max(0, clipView.bounds.origin.y + direction * step), maxY)
            }
            samples.append(measure("Scroll") {
                clipView.scroll(to: NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(clipView)
                window.displayIfNeeded()
            })
            try await Task.sleep(for: pauseBetweenActions)
        }
        return samples
    }

    // MARK: Вспомогательное

    private static func keyEvent(_ type: NSEvent.EventType, _ character: String, window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: character,
                         charactersIgnoringModifiers: character, isARepeat: false, keyCode: character == " " ? 49 : 0)
    }

    private static func measure(_ name: StaticString, _ action: () -> Void) -> Double {
        let state = signposter.beginInterval(name)
        let start = ContinuousClock.now
        action()
        let elapsed = milliseconds(ContinuousClock.now - start)
        signposter.endInterval(name, state)
        return elapsed
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    nonisolated static func p95(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let index = Int((Double(sorted.count) * 0.95).rounded(.up)) - 1
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
