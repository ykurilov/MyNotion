import AppKit
import Foundation
import Navigation
import NotesCore
import PageEditor

/// Замер вкладок (US3, T056; SC-201, SC-202): флаг `--tabs-benchmark <отчёт>`, сборка Release, эталонная база.
/// 20 вкладок с «богатыми» страницами 002 (образец и 19 копий ветки), у каждой своё место прокрутки:
/// 100 переключений по кругу, 10 «назад» и 10 «вперёд» — от команды до готовности редактора и перерисовки окна;
/// место прокрутки после возврата то же; память с одной вкладкой и с двадцатью после переключений.
/// В конце в базе остаются 10 вкладок — тест запускает приложение ещё раз и мерит запуск с ними.
@MainActor
enum TabsBenchmark {
    static let tabCount = 20
    static let switches = 100
    static let historySteps = 10
    static let tabsForLaunch = 10

    private static var hasStarted = false
    private static var readyWaiter: CheckedContinuation<Bool, Never>?
    private static var readyTimeout: Task<Void, Never>?

    struct BenchmarkFailure: Error, CustomStringConvertible {
        let description: String
    }

    struct Report: Codable {
        var switchMs: [Double] = []
        var backMs: [Double] = []
        var forwardMs: [Double] = []
        var switchP95Ms: Double?
        var backP95Ms: Double?
        var forwardP95Ms: Double?
        var memoryOneTabMB: Double?
        var memoryTwentyTabsMB: Double?
        /// Возвратов на вкладку, где блок у верха тот же, что был при уходе, — из скольких проверено.
        var scrollRestored = 0
        var scrollChecked = 0
        var error: String?

        mutating func summarize() {
            switchP95Ms = TypingBenchmark.p95(switchMs)
            backP95Ms = TypingBenchmark.p95(backMs)
            forwardP95Ms = TypingBenchmark.p95(forwardMs)
        }
    }

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
                try await run(model, into: &report)
            } catch {
                report.error = String(describing: error)
            }
            report.summarize()
            if let data = try? JSONEncoder().encode(report) { try? data.write(to: url, options: .atomic) }
            NSApp.terminate(nil)
        }
    }

    private static func run(_ model: MainWindowModel, into report: inout Report) async throws {
        try await Task.sleep(for: .milliseconds(500))
        let store = model.store
        let rich = try RichPageGenerator(parts: BlockKinds.richPageParts).ensure(in: store)
        SampleMedia.materialize(in: store, attachments: model.library.attachments, pageIds: [rich])
        var pages = [rich]
        for number in 1..<tabCount {
            pages.append(try store.write { transaction in
                guard let root = try transaction.page(rich) else { throw NotesStoreError.pageNotFound(rich) }
                return try PageBranchCopier.copy(rich, in: transaction, title: "\(root.title) \(number)", parentId: root.parentId,
                                                 sortKey: .between(root.sortKey, nil)).rootId
            })
        }
        model.library.reloadTree()

        // Одна вкладка: те же 20 страниц и те же 100 переходов, что у вкладок ниже, — память без вкладок.
        try await show(TabsState(active: 0, items: [Tab(pageId: rich)]), in: model)
        for pageId in pages.dropFirst() { _ = try await measure(in: model) { model.select(pageId) } }
        for step in 0..<switches {
            let pageId = pages[(step * 7 + 3) % tabCount]
            if pageId != model.openPageId { _ = try await measure(in: model) { model.select(pageId) } }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .seconds(2))
        report.memoryOneTabMB = footprintMB()

        // 20 вкладок: каждую открыть один раз и прокрутить на своё место.
        try await show(TabsState(active: 0, items: pages.map { Tab(pageId: $0) }), in: model)
        for index in 0..<tabCount {
            if index > 0 { _ = try await measure(in: model) { model.activateTab(index) } }
            scroll(by: 400 + CGFloat(index) * 150)
        }

        for step in 0..<switches {
            var target = (step * 7 + 3) % tabCount
            if target == model.tabs.activeIndex { target = (target + 1) % tabCount }
            let expected = model.tabs.items[target].scroll
            report.switchMs.append(try await measure(in: model) { model.activateTab(target) })
            if let expected {
                report.scrollChecked += 1
                if model.scrollPlace.current()?.blockId == expected.blockId { report.scrollRestored += 1 }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .seconds(2))
        report.memoryTwentyTabsMB = footprintMB()

        // «Назад» и «вперёд» по страницам эталона в одной вкладке.
        let textPages = model.tree.pagesInTreeOrder.map(\.id).filter { !pages.contains($0) }.prefix(historySteps)
        for pageId in textPages {
            _ = try await measure(in: model) { model.select(pageId) }
            scroll(by: 300)
        }
        for _ in 0..<historySteps {
            guard model.canGoBack else { break }
            report.backMs.append(try await measure(in: model) { model.goBack() })
        }
        for _ in 0..<historySteps {
            guard model.canGoForward else { break }
            report.forwardMs.append(try await measure(in: model) { model.goForward() })
        }

        // Для замера запуска: 10 вкладок, активная — «богатая» страница.
        try await show(TabsState(active: 0, items: pages.prefix(tabsForLaunch).map { Tab(pageId: $0) }), in: model)
        model.saveAll()
    }

    /// Поставить вкладки; редактор ждём, только если активная — другая страница (та же страница не открывается заново).
    private static func show(_ state: TabsState, in model: MainWindowModel) async throws {
        let install = {
            model.installTabs(WindowTabs(state: state, openPageId: nil))
            model.showActiveTab(focus: .body)
        }
        if state.items[state.active].pageId == model.openPageId { install() } else { _ = try await measure(in: model, install) }
    }

    /// От команды до готовности редактора новой страницы (с возвратом места прокрутки) и перерисовки окна.
    private static func measure(in model: MainWindowModel, _ action: () -> Void) async throws -> Double {
        let start = ContinuousClock.now
        let ready = await withCheckedContinuation { continuation in
            readyWaiter = continuation
            action()
            readyTimeout = Task {
                guard (try? await Task.sleep(for: .seconds(10))) != nil, let waiter = readyWaiter else { return }
                readyWaiter = nil
                waiter.resume(returning: false)
            }
        }
        readyTimeout?.cancel()
        NSApp.windows.forEach { $0.displayIfNeeded() }
        let elapsed = ContinuousClock.now - start
        guard ready else { throw BenchmarkFailure(description: "Страница вкладки не открылась за 10 с") }
        return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }

    /// Прокрутить открытую страницу вниз: у вкладки появляется своё место.
    private static func scroll(by y: CGFloat) {
        guard let window = NSApp.windows.first(where: { $0.firstResponder is PageTextView }),
              let textView = window.firstResponder as? PageTextView, let scrollView = textView.enclosingScrollView else { return }
        textView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        window.displayIfNeeded()
    }

    private static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }
}
