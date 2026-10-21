import Darwin
import Foundation

/// Сторож главного потока для замеров: главный поток отмечается таймером (`tick`), отдельный поток раз в 10 мс смотрит,
/// давно ли была отметка; если дольше `threshold`, — на миг останавливает главный поток и снимает его стек по цепочке
/// кадров (arm64), с названиями из `dladdr`. Так видно, на чём стоит главный поток во время остановки.
final class ProbeMainThreadWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTick = DispatchTime.now().uptimeNanoseconds
    private var running = true
    private let mainPort: mach_port_t
    private let stackLow: UInt
    private let stackHigh: UInt
    private(set) var captures: [(atMs: Double, frames: [String])] = []
    let threshold: Double

    /// Создавать на главном потоке.
    init(thresholdMs: Double = 150) {
        threshold = thresholdMs
        mainPort = mach_thread_self()
        let thread = pthread_self()
        stackHigh = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        stackLow = stackHigh - UInt(pthread_get_stacksize_np(thread))
        Thread.detachNewThread { [self] in watch() }
    }

    func tick() { lock.withLock { lastTick = DispatchTime.now().uptimeNanoseconds } }

    func stop() { lock.withLock { running = false } }

    private func watch() {
        var capturedForStall = 0
        while lock.withLock({ running }) {
            usleep(10_000)
            let since = Double(DispatchTime.now().uptimeNanoseconds - lock.withLock { lastTick }) / 1e6
            if since < threshold { capturedForStall = 0; continue }
            // По снимку на 150, 400 и 700 мс остановки.
            let marks = [threshold, 400, 700]
            guard capturedForStall < marks.count, since >= marks[capturedForStall] else { continue }
            capturedForStall += 1
            let frames = backtrace()
            lock.withLock { captures.append((since, frames)) }
        }
    }

    private func backtrace() -> [String] {
        guard thread_suspend(mainPort) == KERN_SUCCESS else { return ["не остановить"] }
        defer { thread_resume(mainPort) }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(mainPort, ARM_THREAD_STATE64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return ["нет состояния"] }
        let strip: (UInt64) -> UInt = { UInt($0 & 0x0000_000F_FFFF_FFFF) }
        var addresses = [strip(state.__pc), strip(state.__lr)]
        var frame = UInt(state.__fp)
        while frame >= stackLow, frame + 16 <= stackHigh, addresses.count < 40 {
            let pointer = UnsafePointer<UInt64>(bitPattern: frame)!
            let next = UInt(pointer[0]), ret = strip(pointer[1])
            if ret == 0 { break }
            addresses.append(ret)
            if next <= frame { break }
            frame = next
        }
        return addresses.map { address in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let name = info.dli_sname else { return String(address, radix: 16) }
            return String(cString: name)
        }
    }

    /// Снимки одной строкой: место остановки и до 14 кадров.
    var report: String {
        lock.withLock {
            captures.isEmpty ? "стек не снимался" : captures.map { capture in
                "[\(Int(capture.atMs)) мс] " + capture.frames.prefix(14).joined(separator: " ← ")
            }.joined(separator: " || ")
        }
    }
}
