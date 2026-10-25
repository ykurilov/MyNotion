import Darwin

/// Адрес и подключение UNIX-сокета: общие для приложения (проверка, жив ли прежний сокет) и клиента.
public enum UnixSocket {
    /// `nil` — путь не влезает в `sun_path`.
    public static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        return address
    }

    /// Подключиться; `nil` — сокета нет или никто не слушает (`errno` остаётся от `connect`).
    public static func connect(_ path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        ignoreBrokenPipe(fd)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let failure = errno
            close(fd)
            errno = failure
            return nil
        }
        return fd
    }

    /// Запись в закрытую другой стороной связь — ошибка `EPIPE`, а не сигнал, который завершил бы процесс.
    public static func ignoreBrokenPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }
}
