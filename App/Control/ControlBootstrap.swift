import ControlCommands
import ControlProtocol
import ControlServer
import Foundation
import os

/// Сервер команд приложения (research R13): поднимается, когда база открыта и прерванный импорт откачен, — до этого
/// клиент ждёт сокет. Окна восстановления при запуске у приложения нет, поэтому старт — сразу после библиотеки.
@MainActor
final class ControlBootstrap {
    private static let logger = Logger(subsystem: "cloud.kurilov.mynotion", category: "control")
    private static var current: ControlBootstrap?
    /// Исполнитель команд — и для щелчков по ссылкам `mynotion://`: он есть, даже если сокет занят другой копией.
    private(set) static var executor: CommandExecutor?

    private let server: ControlSocketServer
    private let executor: CommandExecutor

    private init(server: ControlSocketServer, executor: CommandExecutor) {
        self.server = server
        self.executor = executor
    }

    /// Обычный запуск: сокет рядом с базой. Сокет уже слушает другая копия — команды остаются за ней.
    static func start(library: PagesLibrary, importController: NotionImportController? = nil) {
        guard current == nil else { return }
        let socketPath = ControlSocketPath.path(forDatabaseFolder: library.store.database.url.deletingLastPathComponent())
        let host = AppControlHost(library: library, socketPath: socketPath,
                                  transferControl: importController.map { AppTransferControl(importController: $0, sync: library.sync) })
        let executor = CommandExecutor(host: host)
        Self.executor = executor
        let server = ControlSocketServer(path: socketPath) { request, call in
            // Сервер читает запросы на своей очереди; выполнение — на главном потоке (research R2).
            let (stream, continuation) = AsyncStream<ControlResponseLine>.makeStream()
            Task { @MainActor in
                // Срок клиента — от приёма запроса; ушедшему клиенту команда не выполняется.
                for await line in executor.stream(request, receivedAt: call.receivedAt, isClientGone: { call.isClientGone }) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            return stream
        }
        do {
            try server.start()
            current = ControlBootstrap(server: server, executor: executor)
            logger.info("Сервер команд слушает \(socketPath, privacy: .public)")
        } catch {
            logger.error("Сервер команд не запущен: \(String(describing: error), privacy: .public)")
        }
    }

    /// Выход: сокет закрыт и удалён, новые команды получают «приложение не запущено».
    static func stop() {
        current?.server.stop()
        current = nil
    }
}
