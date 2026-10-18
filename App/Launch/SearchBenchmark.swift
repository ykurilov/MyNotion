import AppKit
import os

/// Замер поиска (T054, SC-009: до 100 мс на символ по 1 000 страниц): по флагу `--search-benchmark <путь>`
/// приложение ставит курсор в поле поиска, печатает слова по букве, как человек, и меряет каждое нажатие —
/// от отправки события окну до перерисовки окна и выдачи. Отчёт с p95 — в файл, затем выход.
/// Каждое нажатие — интервал signpost `SearchKeystroke` для Instruments.
@MainActor
enum SearchBenchmark {
    /// Слова из словаря эталонной базы: частые («заметка» есть почти в каждом блоке), латиница, «ё», два слова,
    /// и слово, которого нет.
    static let queries = ["заметка", "проект встреча", "sync", "ёлка", "roadmap", "щука съёмка", "абракадабра"]
    static let rounds = 3
    static let pauseBetweenKeystrokes: Duration = .milliseconds(30)

    private static let signposter = OSSignposter(subsystem: "cloud.kurilov.mynotion", category: .pointsOfInterest)
    private static var hasStarted = false

    struct Report: Encodable {
        var keystrokeMs: [Double] = []
        var keystrokeP95Ms: Double?
        var maxMs: Double?
        /// Сколько страниц нашлось на каждое слово целиком, по порядку `queries`.
        var resultCounts: [Int] = []
        var error: String?
    }

    struct BenchmarkFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func editorReady(model: MainWindowModel, reportTo url: URL) {
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            var report = Report()
            do {
                report = try await run(model)
            } catch {
                report.error = String(describing: error)
            }
            report.keystrokeP95Ms = TypingBenchmark.p95(report.keystrokeMs)
            report.maxMs = report.keystrokeMs.max()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: url, options: .atomic)
            NSApp.terminate(nil)
        }
    }

    private static func run(_ model: MainWindowModel) async throws -> Report {
        var report = Report()
        try await Task.sleep(for: .milliseconds(500))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            throw BenchmarkFailure(description: "Нет окна")
        }
        for round in 0..<rounds {
            for query in queries {
                model.search.focusField()
                guard window.firstResponder is NSTextView else { throw BenchmarkFailure(description: "Поле поиска не в фокусе") }
                for character in query {
                    let text = String(character)
                    guard let keyDown = keyEvent(.keyDown, text, window: window), let keyUp = keyEvent(.keyUp, text, window: window) else {
                        throw BenchmarkFailure(description: "Не удалось создать событие клавиши")
                    }
                    report.keystrokeMs.append(measure {
                        window.sendEvent(keyDown)
                        NSApp.windows.forEach { $0.displayIfNeeded() }
                    })
                    window.sendEvent(keyUp)
                    try await Task.sleep(for: pauseBetweenKeystrokes)
                }
                guard model.search.query == query else {
                    throw BenchmarkFailure(description: "В поле «\(model.search.query)», печатали «\(query)»")
                }
                guard model.search.isShowingResults else { throw BenchmarkFailure(description: "Выдача «\(query)» не на экране") }
                if round == 0 { report.resultCounts.append(model.search.results.count) }
                model.search.dismiss()
                try await Task.sleep(for: pauseBetweenKeystrokes)
            }
        }
        return report
    }

    private static func keyEvent(_ type: NSEvent.EventType, _ character: String, window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: character,
                         charactersIgnoringModifiers: character, isARepeat: false, keyCode: character == " " ? 49 : 0)
    }

    private static func measure(_ action: () -> Void) -> Double {
        let state = signposter.beginInterval("SearchKeystroke")
        let start = ContinuousClock.now
        action()
        let elapsed = ContinuousClock.now - start
        signposter.endInterval("SearchKeystroke", state)
        return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }
}
