import ControlProtocol
import Darwin
import Foundation

/// Обмен по сокету: один запрос — строки `progress` и итоговая строка ответа.
enum SocketClient {
    /// Подключиться к приложению; `nil` — сокета нет или никто не слушает.
    static func connect(_ path: String) -> Int32? {
        guard let fd = UnixSocket.connect(path) else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Отправить запрос и дочитать ответ до срока `request.timeoutMs`. Закрывает `fd`.
    static func exchange(_ fd: Int32, _ request: ControlRequest, onProgress: (ControlProgress) -> Void) -> ControlResponse {
        defer { close(fd) }
        let deadline = ContinuousClock.now + .milliseconds(request.timeoutMs)
        do {
            // Запись может оборваться: приложение отказало, не дочитав запрос (слишком большой). Его отказ уже в сокете —
            // читаем ответ всё равно; нет ответа — обрыв связи.
            _ = try writeAll(LineFraming.frame(request), to: fd)
        } catch {
            return .failure(request.id, ControlError(.invalidArgument, "Запрос не превратить в JSON: \(error.localizedDescription)"))
        }

        // Ответ бывает больше запроса (страница целиком): предел строки ответа — с запасом.
        var buffer = LineBuffer(limit: ControlProtocolVersion.maxFrameBytes * 4)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return timedOut(request) }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining.milliseconds, Int64(Int32.max))) + 1)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return ready == 0 ? timedOut(request) : disconnected(request) }

            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return disconnected(request) }
            let lines: [Data]
            do {
                lines = try buffer.append(Data(chunk[0..<count]))
            } catch {
                return .failure(request.id, ControlError(.internal, "Ответ приложения слишком велик"))
            }
            for line in lines {
                guard let decoded = try? LineFraming.decode(ControlResponseLine.self, from: line) else {
                    return .failure(request.id, ControlError(.internal, "Приложение прислало строку, которую не разобрать"))
                }
                switch decoded {
                case .progress(_, let progress): onProgress(progress)
                case .result(let response): return response
                }
            }
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    private static func timedOut(_ request: ControlRequest) -> ControlResponse {
        .failure(request.id, ControlError(.timeout, "Приложение не ответило за \(request.timeoutMs) мс",
                                          hint: "Больше срок: --timeout <мс>. Изменение могло примениться — проверьте чтением",
                                          details: ["timeoutMs": .number(Double(request.timeoutMs))]))
    }

    private static func disconnected(_ request: ControlRequest) -> ControlResponse {
        .failure(request.id, ControlError(.appDisconnected, "Приложение закрыло связь, не дав ответа",
                                          hint: "Проверьте состояние: mynotion app status"))
    }
}

extension Duration {
    fileprivate var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}
