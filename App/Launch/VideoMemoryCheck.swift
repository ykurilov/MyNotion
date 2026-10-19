import AppKit
import Darwin
import EmbeddedMedia
import LinkPreview

/// `--video-memory-check <путь>`: живой замер памяти YouTube (research R8, T098) в виртуальном Mac. В покое,
/// во время игры проигрывателя YouTube в окне и через 10 с после его закрытия: память приложения (phys_footprint)
/// и процессов WebKit. Итог — в файл и в вывод, затем выход. Бюджет: в покое после закрытия — исходная ± 10 МБ.
@MainActor
enum VideoMemoryCheck {
    static let playSeconds: Double = 20
    static let settleSeconds: Double = 10

    static func start(window: NSWindow?, reportTo url: URL) {
        Task {
            try? await Task.sleep(for: .seconds(3))
            let idle = snapshot()
            guard let content = window?.contentView else { return finish("Замер видео: нет окна", url) }
            let player = WebVideoPlayerView(embedURL: VideoLink.youtube(id: "aqz-KE-bpKQ").embedURL)
            player.frame = NSRect(x: 40, y: 40, width: 720, height: 405)
            content.addSubview(player)
            player.play()
            try? await Task.sleep(for: .seconds(playSeconds))
            let playing = snapshot()
            player.removeFromSuperview()
            try? await Task.sleep(for: .seconds(settleSeconds))
            let after = snapshot()
            let delta = Double(Int64(after.app) - Int64(idle.app)) / 1_048_576
            let verdict = abs(delta) <= 10 ? "в бюджете ± 10 МБ" : "ВНЕ бюджета ± 10 МБ"
            finish("""
                Память в покое до видео: приложение \(mb(idle.app)), WebKit \(mb(idle.web))
                Во время игры YouTube: приложение \(mb(playing.app)), WebKit \(mb(playing.web)), всего \(mb(playing.app + playing.web))
                Через \(Int(settleSeconds)) с после закрытия: приложение \(mb(after.app)), WebKit \(mb(after.web)); \
                разница приложения с покоем \(String(format: "%+.1f", delta)) МБ (\(verdict))
                """, url)
        }
    }

    private static func finish(_ text: String, _ url: URL) {
        print(text)
        try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private static func mb(_ bytes: UInt64) -> String { String(format: "%.1f МБ", Double(bytes) / 1_048_576) }

    /// Память приложения и всех процессов WebKit (в виртуальном Mac других пользователей WebKit нет).
    private static func snapshot() -> (app: UInt64, web: UInt64) {
        (footprint(of: getpid()) ?? 0, webKitPids().compactMap(footprint(of:)).reduce(0, +))
    }

    private static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    private static func webKitPids() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 4_096)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(0, count))).filter { pid in
            var name = [CChar](repeating: 0, count: 256)
            proc_name(pid, &name, UInt32(name.count))
            return String(cString: name).hasPrefix("com.apple.WebKit")
        }
    }
}
