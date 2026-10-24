import ControlProtocol
import Darwin
import Foundation

/// Кто на том конце сокета: свой пользователь или нет (research R1, `getpeereid`).
public protocol PeerCredentials: Sendable {
    func userID(ofPeer socket: Int32) -> uid_t?
}

public struct KernelPeerCredentials: PeerCredentials {
    public init() {}

    public func userID(ofPeer socket: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(socket, &uid, &gid) == 0 ? uid : nil
    }
}

/// Сокет команд приложения (research R1, R2): файл `0600`, только свой пользователь, на подключение — один запрос
/// строкой JSON и ответ строками (ход, итог). Разрыв связи клиентом команду не отменяет: её ответ дочитывается впустую.
public final class ControlSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) -> AsyncStream<ControlResponseLine>

    public enum StartFailure: Error, Equatable {
        /// Сокет слушает другая копия приложения.
        case otherInstanceRunning
        case socketFailed(errno: Int32)
    }

    /// Сколько ждать строку запроса от подключившегося.
    static let requestReadTimeout: Int = 30

    public let path: String
    private let credentials: any PeerCredentials
    private let handler: Handler
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var source: (any DispatchSourceRead)?
    private let acceptQueue = DispatchQueue(label: "MyNotion.ControlSocketServer.accept")

    public init(path: String, credentials: any PeerCredentials = KernelPeerCredentials(), handler: @escaping Handler) {
        self.path = path
        self.credentials = credentials
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        let fd = try bindListener()
        lock.withLock { listener = fd }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        source.setCancelHandler { close(fd) }
        lock.withLock { self.source = source }
        source.resume()
    }

    /// Перестать слушать и убрать файл сокета. Идущие команды доводятся до конца.
    public func stop() {
        let source = lock.withLock { () -> (any DispatchSourceRead)? in
            let current = self.source
            self.source = nil
            listener = -1
            return current
        }
        guard let source else { return }
        source.cancel()
        unlink(path)
    }

    // MARK: Слушатель

    private func bindListener() throws -> Int32 {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartFailure.socketFailed(errno: errno) }
        var bound = Self.bind(fd, to: path)
        if !bound, errno == EADDRINUSE {
            // Файл есть: живой сокет другой копии не трогаем, оставшийся от упавшего приложения — заменяем.
            if Self.isAlive(path) {
                close(fd)
                throw StartFailure.otherInstanceRunning
            }
            unlink(path)
            bound = Self.bind(fd, to: path)
        }
        guard bound else {
            let code = errno
            close(fd)
            throw StartFailure.socketFailed(errno: code)
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw StartFailure.socketFailed(errno: code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    /// `bind` под `umask 077`: файл сокета сразу только для владельца.
    private static func bind(_ fd: Int32, to path: String) -> Bool {
        guard var address = UnixSocket.address(path) else {
            errno = ENAMETOOLONG
            return false
        }
        let previous = umask(0o077)
        defer { umask(previous) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    private static func isAlive(_ path: String) -> Bool {
        guard let fd = UnixSocket.connect(path) else { return false }
        close(fd)
        return true
    }

    private func acceptPending(on listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            // Подключение наследует O_NONBLOCK слушателя: чтение запроса — блокирующее со сроком.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: Self.requestReadTimeout, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard credentials.userID(ofPeer: client) == getuid() else {
                close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [handler] in
                Connection(fd: client, handler: handler).serve()
            }
        }
    }
}

/// Одно подключение: строка запроса → строки ответа.
private struct Connection: Sendable {
    let fd: Int32
    let handler: ControlSocketServer.Handler

    func serve() {
        let request: ControlRequest
        switch readRequest() {
        case .none:
            close(fd)
            return
        case .some(.rejected(let response)):
            _ = Self.send(.result(response), to: fd)
            close(fd)
            return
        case .some(.request(let value)):
            request = value
        }
        let stream = handler(request)
        let fd = fd
        Task.detached {
            var isConnected = true
            // Ушедший клиент: ответ дочитывается впустую, чтобы команда закончилась сама.
            for await line in stream where isConnected {
                isConnected = Self.send(line, to: fd)
            }
            close(fd)
        }
    }

    private enum Probe: Decodable {
        case version(Int?, id: String?)

        private enum Keys: String, CodingKey { case `protocol`, id }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            self = .version(try? container.decode(Int.self, forKey: .protocol), id: try? container.decode(String.self, forKey: .id))
        }
    }

    /// Прочитанная строка: запрос или готовый отказ.
    private enum Incoming {
        case request(ControlRequest)
        case rejected(ControlResponse)
    }

    /// `nil` — клиент ушёл, ничего не прислав.
    private func readRequest() -> Incoming? {
        var buffer = LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                let rest = buffer.remainder
                return rest.isEmpty ? nil : decode(rest)
            }
            do {
                if let line = try buffer.append(Data(chunk[0..<count])).first { return decode(line) }
            } catch {
                return .rejected(.failure("", ControlError(.invalidArgument, "Запрос больше \(ControlProtocolVersion.maxFrameBytes / 1_048_576) МБ",
                                                          hint: "Большие данные — файлом через --file")))
            }
        }
    }

    private func decode(_ line: Data) -> Incoming {
        guard case .version(let version, let id)? = try? LineFraming.decode(Probe.self, from: line) else {
            return .rejected(.failure("", ControlError(.invalidArgument, "Запрос — не JSON", hint: "Одна строка JSON по contracts/protocol.md")))
        }
        if let version, version != ControlProtocolVersion.current {
            return .rejected(.failure(id ?? "", ControlError(
                .versionMismatch, "Версия команды mynotion (\(version)) не совпадает с приложением (\(ControlProtocolVersion.current))",
                hint: "Обновите ссылку: scripts/install-cli.sh",
                details: ["app": .string(String(ControlProtocolVersion.current)), "client": .string(String(version))])))
        }
        do {
            return .request(try LineFraming.decode(ControlRequest.self, from: line))
        } catch {
            return .rejected(.failure(id ?? "", ControlError(.invalidArgument, "Неверный запрос: \(error.localizedDescription)",
                                                            hint: "Поля запроса — contracts/protocol.md")))
        }
    }

    /// `false` — клиента больше нет.
    static func send(_ line: ControlResponseLine, to fd: Int32) -> Bool {
        guard let data = try? LineFraming.frame(line) else { return false }
        return data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
