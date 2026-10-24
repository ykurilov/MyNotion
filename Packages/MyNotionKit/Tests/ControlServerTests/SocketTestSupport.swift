import ControlProtocol
import Darwin
import Foundation

/// Короткая временная папка: путь сокета не длиннее `sun_path`.
final class SocketFolder {
    let url: URL

    init() {
        url = URL(fileURLWithPath: "/tmp/mn-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var socketPath: String { url.appendingPathComponent("c.sock").path }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Простой клиент на сыром сокете: проверки сервера без модуля клиента.
enum RawClient {
    static func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() where index < buffer.count - 1 { buffer[index] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func write(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    /// Все строки до закрытия связи.
    static func readLines(_ fd: Int32) -> [String] {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    static func exchange(_ request: ControlRequest, path: String) throws -> [ControlResponseLine] {
        guard let fd = connect(path) else { throw CocoaError(.fileNoSuchFile) }
        defer { close(fd) }
        write(try LineFraming.frame(request), to: fd)
        return try readLines(fd).map { try LineFraming.decode(ControlResponseLine.self, from: Data($0.utf8)) }
    }
}
