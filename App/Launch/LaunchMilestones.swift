import Darwin
import Foundation
import os

/// Готовность окна к вводу: метка `EditorReady` для замеров (T016) и, по флагу
/// `--launch-report`, файл с временем запуска и памятью в покое.
@MainActor
enum LaunchMilestones {
    static let signposter = OSSignposter(subsystem: "cloud.kurilov.mynotion", category: .pointsOfInterest)
    /// Покой перед замером памяти (research R13).
    static let idleBeforeMemoryMeasurement: Duration = .seconds(10)

    private static var hasReportedEditorReady = false

    static func editorReady(reportTo reportURL: URL?) {
        guard !hasReportedEditorReady else { return }
        hasReportedEditorReady = true
        signposter.emitEvent("EditorReady")

        let readyAt = Date().timeIntervalSince1970
        guard let reportURL, let launchSeconds = secondsSinceProcessStart(at: readyAt) else { return }
        var report = LaunchReport(launchSeconds: launchSeconds, editorReadyAt: readyAt)
        report.write(to: reportURL)
        Task {
            try? await Task.sleep(for: idleBeforeMemoryMeasurement)
            report.idleMemoryBytes = physicalFootprint()
            report.write(to: reportURL)
        }
    }

    /// Время от запуска процесса ядром до `moment` (секунды с 1970 года).
    private static func secondsSinceProcessStart(at moment: Double) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let started = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
        return moment - started
    }

    /// Память процесса так, как её показывает «Мониторинг системы» (phys_footprint).
    private static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

struct LaunchReport: Codable {
    /// От запуска процесса ядром до `EditorReady`.
    var launchSeconds: Double
    /// Момент `EditorReady`, секунды с 1970 года: тест считает от своей просьбы запустить.
    var editorReadyAt: Double
    var idleMemoryBytes: UInt64?

    func write(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
