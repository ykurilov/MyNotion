import ControlProtocol
import Darwin
import Foundation
import Synchronization

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
/// строкой JSON и ответ строками (ход, итог). Чтение и запись не блокируют потоки: у запроса общий срок, у ответа —
/// срок на то, чтобы клиент его забирал. Подключений одновременно — не больше `Limits.maxConnections`.
/// Разрыв связи клиентом команду не отменяет: её ответ дочитывается впустую, а `ControlCall.isClientGone` это видит.
public final class ControlSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest, ControlCall) -> AsyncStream<ControlResponseLine>

    /// Пределы одного подключения и их числа.
    public struct Limits: Sendable {
        /// Срок на всю строку запроса от подключения: медленный по байту клиент тоже упирается в него.
        public var requestTimeout: Duration
        /// Сколько ждать, пока клиент заберёт ответ; дольше — клиент считается ушедшим.
        public var sendTimeout: Duration
        public var maxConnections: Int
        public var maxRequestBytes: Int

        public init(requestTimeout: Duration = .seconds(10), sendTimeout: Duration = .seconds(10), maxConnections: Int = 64,
                    maxRequestBytes: Int = ControlProtocolVersion.maxFrameBytes) {
            self.requestTimeout = requestTimeout
            self.sendTimeout = sendTimeout
            self.maxConnections = maxConnections
            self.maxRequestBytes = maxRequestBytes
        }

        public static let standard = Limits()
    }

    public enum StartFailure: Error, Equatable {
        /// Сокет слушает другая копия приложения.
        case otherInstanceRunning
        case socketFailed(errno: Int32)
    }

    public let path: String
    private let credentials: any PeerCredentials
    private let limits: Limits
    private let handler: Handler
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var source: (any DispatchSourceRead)?
    private var openConnections = 0
    private let acceptQueue = DispatchQueue(label: "MyNotion.ControlSocketServer.accept")

    public init(path: String, credentials: any PeerCredentials = KernelPeerCredentials(), limits: Limits = .standard,
                handler: @escaping Handler) {
        self.path = path
        self.credentials = credentials
        self.limits = limits
        self.handler = handler
    }

    deinit { stop() }

    /// Открытые подключения — для тестов.
    var openConnectionCount: Int { lock.withLock { openConnections } }

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
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            guard credentials.userID(ofPeer: client) == getuid() else {
                close(client)
                continue
            }
            let admitted = lock.withLock { () -> Bool in
                guard openConnections < limits.maxConnections else { return false }
                openConnections += 1
                return true
            }
            guard admitted else {
                Self.refuseBusy(client)
                continue
            }
            Connection(fd: client, limits: limits, handler: handler) { [weak self] in
                self?.lock.withLock { self?.openConnections -= 1 }
            }.start()
        }
    }

    /// Мест нет: короткий отказ без чтения запроса — строка влезает в пустой буфер сокета.
    private static func refuseBusy(_ fd: Int32) {
        let refusal = ControlResponse.failure("", ControlError(.appNotReady, "Слишком много одновременных подключений к MyNotion",
                                                               hint: "Повторите команду чуть позже"))
        if let data = try? LineFraming.frame(ControlResponseLine.result(refusal)) {
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
        }
        close(fd)
    }
}

/// Один принятый запрос: когда пришёл и на месте ли ещё клиент.
public final class ControlCall: Sendable {
    /// Приём подключения: срок клиента (`timeoutMs`) отсчитывается от него.
    public let receivedAt: ContinuousClock.Instant
    private let gone = Mutex(false)

    init(receivedAt: ContinuousClock.Instant = .now) {
        self.receivedAt = receivedAt
    }

    /// Клиент закрыл связь или перестал забирать ответ: ждать его больше некому.
    public var isClientGone: Bool { gone.withLock { $0 } }

    func markClientGone() {
        gone.withLock { $0 = true }
    }
}

/// Одно подключение: строка запроса → строки ответа. Всё состояние — на своей последовательной очереди;
/// сокет неблокирующий, чтение и запись — по событиям `DispatchSource`, сроки — одним таймером.
private final class Connection: @unchecked Sendable {
    private enum Phase {
        /// Ждём строку запроса (срок `requestTimeout` на всю строку).
        case reading
        /// Запрос слишком велик и уже отклонён: дочитываем вход впустую, чтобы клиент дописал и прочёл отказ.
        case draining
        /// Отвечаем: строки ответа уходят по мере того, как клиент их забирает.
        case answering
        case closed
    }

    private let fd: Int32
    private let limits: ControlSocketServer.Limits
    private let handler: ControlSocketServer.Handler
    private let onClose: @Sendable () -> Void
    private let queue = DispatchQueue(label: "MyNotion.ControlSocketServer.connection")
    private let call = ControlCall()

    private var phase = Phase.reading
    private var buffer: LineBuffer
    private var reader: (any DispatchSourceRead)?
    private var writer: (any DispatchSourceWrite)?
    private var isWriterSuspended = true
    private var timer: (any DispatchSourceTimer)?
    private var liveSources = 0
    private var outgoing = Data()
    private var sentCount = 0
    private var isAnswerComplete = false

    init(fd: Int32, limits: ControlSocketServer.Limits, handler: @escaping ControlSocketServer.Handler, onClose: @escaping @Sendable () -> Void) {
        self.fd = fd
        self.limits = limits
        self.handler = handler
        self.onClose = onClose
        buffer = LineBuffer(limit: limits.maxRequestBytes)
    }

    func start() {
        queue.async { self.begin() }
    }

    private func begin() {
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { self.readAvailable() }
        reader.setCancelHandler { self.sourceCancelled() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { self.deadlinePassed() }
        timer.setCancelHandler { self.sourceCancelled() }
        self.reader = reader
        self.timer = timer
        liveSources = 2
        arm(after: limits.requestTimeout)
        timer.resume()
        reader.resume()
    }

    // MARK: Чтение

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while phase != .closed {
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            guard count > 0 else { return inputEnded() }
            guard phase == .reading else { continue }
            do {
                if let line = try buffer.append(Data(chunk[0..<count])).first { return answer(decode(line)) }
            } catch {
                let limit = limits.maxRequestBytes
                let size = limit >= 1_048_576 ? "\(limit / 1_048_576) МБ" : "\(limit) байт"
                reject(ControlResponse.failure("", ControlError(.invalidArgument, "Запрос больше \(size)", hint: "Большие данные — файлом через --file")))
            }
        }
    }

    /// Клиент закрыл запись (EOF).
    private func inputEnded() {
        switch phase {
        case .reading:
            let rest = buffer.remainder
            stopReading()
            guard !rest.isEmpty else { return finish() }
            answer(decode(rest))
            // Запрос без `\n` в конце и полное закрытие — отвечать уже некому.
            if Self.peerClosedCompletely(fd) { clientLeft() }
        case .draining:
            finish()
        case .answering:
            stopReading()
            // Закрыта только запись (`shutdown`, как `nc -N`) — клиент ждёт ответа; закрыт сокет целиком — ушёл.
            if Self.peerClosedCompletely(fd) { clientLeft() }
        case .closed:
            break
        }
    }

    /// После EOF: `POLLHUP` на запись бывает, только если клиент закрыл сокет целиком, а не одну свою запись.
    private static func peerClosedCompletely(_ fd: Int32) -> Bool {
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        return poll(&poller, 1, 0) > 0 && poller.revents & Int16(POLLHUP | POLLERR) != 0
    }

    private func stopReading() {
        guard let reader else { return }
        self.reader = nil
        reader.cancel()
    }

    // MARK: Ответ

    private func answer(_ incoming: Incoming) {
        switch incoming {
        case .rejected(let response):
            phase = .answering
            disarm()
            enqueue(.result(response))
            answerComplete()
        case .request(let request):
            phase = .answering
            disarm()
            let stream = handler(request, call)
            Task.detached { [self] in
                // Ушедший клиент: ответ дочитывается впустую, чтобы команда закончилась сама.
                for await line in stream { queue.async { self.enqueue(line) } }
                queue.async { self.answerComplete() }
            }
        }
    }

    /// Отказ посреди слишком длинного запроса: отказ — сразу, вход — дочитать впустую, пока клиент не закроет связь.
    private func reject(_ response: ControlResponse) {
        phase = .draining
        buffer = LineBuffer(limit: 0)
        enqueue(.result(response))
        arm(after: limits.requestTimeout)
    }

    private func enqueue(_ line: ControlResponseLine) {
        guard phase == .answering || phase == .draining, let data = try? LineFraming.frame(line) else { return }
        outgoing.append(data)
        flush()
    }

    private func answerComplete() {
        isAnswerComplete = true
        if phase == .answering, sentCount == outgoing.count { finish() }
    }

    private func flush() {
        var progressed = false
        while sentCount < outgoing.count {
            let written = outgoing.withUnsafeBytes { raw in write(fd, raw.baseAddress! + sentCount, raw.count - sentCount) }
            if written > 0 {
                sentCount += written
                progressed = true
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                waitUntilWritable(restartingDeadline: progressed)
                return
            }
            return clientLeft()
        }
        outgoing.removeAll(keepingCapacity: false)
        sentCount = 0
        if let writer, !isWriterSuspended {
            writer.suspend()
            isWriterSuspended = true
        }
        if phase == .answering {
            disarm()
            if isAnswerComplete { finish() }
        }
    }

    private func waitUntilWritable(restartingDeadline: Bool) {
        if writer == nil {
            let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            writer.setEventHandler { self.flush() }
            writer.setCancelHandler { self.sourceCancelled() }
            self.writer = writer
            liveSources += 1
        }
        if isWriterSuspended {
            writer?.resume()
            isWriterSuspended = false
            arm(after: limits.sendTimeout)
        } else if restartingDeadline, phase == .answering {
            arm(after: limits.sendTimeout)
        }
    }

    // MARK: Сроки и закрытие

    private func arm(after delay: Duration) {
        let (seconds, attoseconds) = delay.components
        let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        timer?.schedule(deadline: .now() + .nanoseconds(nanoseconds))
    }

    private func disarm() {
        timer?.schedule(deadline: .distantFuture)
    }

    private func deadlinePassed() {
        switch phase {
        case .reading, .draining: finish()
        // Клиент не забирает ответ: считаем его ушедшим, команда дорабатывает впустую.
        case .answering: clientLeft()
        case .closed: break
        }
    }

    private func clientLeft() {
        call.markClientGone()
        finish()
    }

    private func finish() {
        guard phase != .closed else { return }
        phase = .closed
        outgoing = Data()
        sentCount = 0
        stopReading()
        if let writer {
            if isWriterSuspended { writer.resume() }
            self.writer = nil
            writer.cancel()
        }
        timer?.cancel()
        timer = nil
    }

    /// Сокет закрывается, когда все источники событий сняты: иначе номер `fd` мог бы достаться чужому файлу.
    private func sourceCancelled() {
        liveSources -= 1
        guard phase == .closed, liveSources == 0 else { return }
        close(fd)
        onClose()
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
}
