import AppKit
import Backlinks
import NotesCore

/// Замер первого заполнения индекса обратных ссылок (T074, SC-206): по флагу `--backlink-benchmark <путь>`
/// приложение размечает ссылками каждый пятый блок (в эталоне их нет; база должна быть копией), стирает индекс и отметку «построен», заполняет индекс заново, как после первого запуска v7,
/// и пока он строится, меряет две вещи, которые человек почувствует за набором:
/// - самую долгую остановку главного потока (таймер раз в 10 мс; остановка = опоздание таймера);
/// - сколько ждёт обычная запись (как при наборе) раз в 20 мс, пока идёт заполнение.
/// Отчёт с временем заполнения — в файл, затем выход.
@MainActor
enum BacklinkBenchmark {
    static let timerInterval: TimeInterval = 0.010
    /// Каждый пятый блок эталона (20 000 из 100 000) — со ссылкой на страницу: плотнее любой настоящей библиотеки.
    static let seededBlockStep = 5
    static let writeInterval: Duration = .milliseconds(20)
    private static var hasStarted = false

    struct Report: Encodable {
        var pageCount = 0
        var blockCount = 0
        var linkCount = 0
        /// Сколько блоков получили ссылку на страницу для замера: в эталонной базе их нет.
        var seededBlockCount = 0
        var buildSeconds: Double?
        /// Опоздания таймера главного потока во время заполнения, мс (0 — таймер пришёл вовремя).
        var mainThreadStallMsP95: Double?
        var mainThreadStallMsMax: Double?
        var writeLatencyMs: [Double] = []
        var writeLatencyMsP95: Double?
        var writeLatencyMsMax: Double?
        var error: String?
    }

    static func editorReady(store: NotesStore, reportTo url: URL) {
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            var report = Report()
            do {
                try await run(store: store, report: &report)
            } catch {
                report.error = String(describing: error)
            }
            report.writeLatencyMsP95 = TypingBenchmark.p95(report.writeLatencyMs)
            report.writeLatencyMsMax = report.writeLatencyMs.max()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: url, options: .atomic)
            NSApp.terminate(nil)
        }
    }

    private static func run(store: NotesStore, report: inout Report) async throws {
        // Редактор уже на экране; даём окну успокоиться, чтобы его первые кадры не попали в замер.
        try await Task.sleep(for: .seconds(1))
        let build = BacklinkIndexBuild(store: store)
        report.seededBlockCount = try build.seedMentionsForBenchmark(everyNthBlock: seededBlockStep)
        try build.reset()
        (report.pageCount, report.blockCount, _) = try build.counts()

        let stalls = StallRecorder()
        stalls.start()
        let writes = Task.detached { () -> [Double] in
            var latencies: [Double] = []
            var counter = 0
            while !Task.isCancelled {
                counter += 1
                let started = ContinuousClock.now
                try? store.setAppMeta("backlinkBenchmarkPing", String(counter))
                latencies.append((ContinuousClock.now - started).milliseconds)
                try? await Task.sleep(for: writeInterval)
            }
            return latencies
        }

        let started = ContinuousClock.now
        let finished = try await Task.detached(priority: .utility) { try await build.runIfNeeded() }.value
        report.buildSeconds = (ContinuousClock.now - started).milliseconds / 1000
        writes.cancel()
        report.writeLatencyMs = await writes.value
        stalls.stop()
        NotificationCenter.default.post(name: .backlinkIndexDidBuild, object: nil)

        report.mainThreadStallMsP95 = TypingBenchmark.p95(stalls.latenessMs)
        report.mainThreadStallMsMax = stalls.latenessMs.max()
        report.linkCount = try build.counts().links
        try store.setAppMeta("backlinkBenchmarkPing", nil)
        if !finished { report.error = "Индекс уже был построен: замер ничего не заполнял" }
    }

    /// Таймер на главном потоке: насколько он опаздывает — столько окно «стояло».
    @MainActor
    private final class StallRecorder {
        private(set) var latenessMs: [Double] = []
        private var timer: Timer?
        private var lastFire = ContinuousClock.now

        func start() {
            lastFire = .now
            timer = Timer.scheduledTimer(withTimeInterval: BacklinkBenchmark.timerInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = ContinuousClock.now
                    self.latenessMs.append(max((now - self.lastFire).milliseconds - BacklinkBenchmark.timerInterval * 1000, 0))
                    self.lastFire = now
                }
            }
        }

        func stop() { timer?.invalidate() }
    }
}

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
