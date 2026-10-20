import AppKit
import Foundation
import NotesCore
import PageEditor

/// Память при переходах между «богатыми» страницами (US3, T056): флаг `--rich-memory-check <отчёт>`, сборка Release.
/// 20 «богатых» страниц 002 (образец и 19 копий ветки) в одной вкладке: 20 переходов прогрева, затем 120 переходов;
/// память (phys_footprint) — после прогрева и 30 с покоя, каждые 20 переходов, через 10 и 30 с покоя в конце. Перед выходом приложение ждёт
/// `MYNOTION_MEMORY_HOLD` секунд: в это время снимают `heap`, `leaks`, `vmmap`.
@MainActor
enum RichPagesMemoryCheck {
    static let pageCount = 20
    static let navigations = 120

    struct Report: Codable {
        var memoryMB: [Double] = []
        /// Живые объекты кучи (malloc, `size_in_use`) — после прогрева и в конце, оба после покоя.
        var heapInUseMB: [Double] = []
        var error: String?
        var isHolding = false
        var isHoldingStart = false
    }

    private static var hasStarted = false
    private static var readyWaiter: CheckedContinuation<Void, Never>?

    static func editorReady(model: MainWindowModel, reportTo url: URL) {
        if let waiter = readyWaiter {
            readyWaiter = nil
            waiter.resume()
            return
        }
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            var report = Report()
            do {
                try await run(model, report: &report, url: url)
            } catch {
                report.error = String(describing: error)
            }
            report.isHolding = false
            write(report, to: url)
            NSApp.terminate(nil)
        }
    }

    private static func run(_ model: MainWindowModel, report: inout Report, url: URL) async throws {
        try await Task.sleep(for: .milliseconds(500))
        let store = model.store
        let rich = try RichPageGenerator(parts: BlockKinds.richPageParts).ensure(in: store)
        SampleMedia.materialize(in: store, attachments: model.library.attachments, pageIds: [rich])
        var pages = [rich]
        for number in 1..<pageCount {
            pages.append(try store.write { transaction in
                guard let root = try transaction.page(rich) else { throw NotesStoreError.pageNotFound(rich) }
                return try PageBranchCopier.copy(rich, in: transaction, title: "\(root.title) \(number)", parentId: root.parentId,
                                                 sortKey: .between(root.sortKey, nil)).rootId
            })
        }
        model.library.reloadTree()
        for pageId in pages { await open(pageId, in: model) }
        // Точка отсчёта — так же после покоя, как и итог: AppKit отпускает часть закрытых видов не сразу.
        try await Task.sleep(for: .seconds(30))
        report.memoryMB.append(footprintMB())
        report.heapInUseMB.append(heapInUseMB())
        if let hold = Double(ProcessInfo.processInfo.environment["MYNOTION_MEMORY_HOLD_START"] ?? ""), hold > 0 {
            report.isHoldingStart = true
            write(report, to: url)
            try await Task.sleep(for: .seconds(hold))
            report.isHoldingStart = false
        }
        for step in 1...navigations {
            var pageId = pages[(step * 7 + 3) % pageCount]
            if pageId == model.openPageId { pageId = pages[(step * 7 + 4) % pageCount] }
            await open(pageId, in: model)
            try await Task.sleep(for: .milliseconds(Int(ProcessInfo.processInfo.environment["MYNOTION_MEMORY_PAUSE_MS"] ?? "") ?? 10))
            if step % 20 == 0 {
                try await Task.sleep(for: .seconds(1))
                report.memoryMB.append(footprintMB())
            }
        }
        // Освобождает ли AppKit закрытые виды со временем: память через 10 и 30 с покоя.
        try await Task.sleep(for: .seconds(10))
        report.memoryMB.append(footprintMB())
        try await Task.sleep(for: .seconds(20))
        report.memoryMB.append(footprintMB())
        report.heapInUseMB.append(heapInUseMB())
        let hold = Double(ProcessInfo.processInfo.environment["MYNOTION_MEMORY_HOLD"] ?? "") ?? 0
        if hold > 0 {
            report.isHolding = true
            write(report, to: url)
            try await Task.sleep(for: .seconds(hold))
        }
    }

    private static func open(_ pageId: UUID, in model: MainWindowModel) async {
        await withCheckedContinuation { continuation in
            readyWaiter = continuation
            model.select(pageId)
        }
        NSApp.windows.forEach { $0.displayIfNeeded() }
    }

    private static func write(_ report: Report, to url: URL) {
        if let data = try? JSONEncoder().encode(report) { try? data.write(to: url, options: .atomic) }
    }

    private static func heapInUseMB() -> Double {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Double(stats.size_in_use) / 1_048_576
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
