import ControlProtocol
import Foundation
import NotesCore

/// Выполнение запросов на главном потоке (research R2): проверка по каталогу до обработчика, запись — под замком
/// и одним шагом отмены (ошибка откатывает сделанное), чтение — без замка. Строка журнала на каждую команду.
@MainActor
public final class CommandExecutor {
    let host: any ControlHost
    let registry: HandlerRegistry
    let log: any CommandLogging
    private let writeLock = WriteLock()
    /// Сессия последней записи — только для тестов: отмена держит операции сессии без сильной ссылки.
    private var lastContext: SessionContext?
    /// Отмена последней выполненной команды — только для тестов.
    public var lastUndoManager: UndoManager? { lastContext?.undoManager }

    public init(host: any ControlHost, registry: HandlerRegistry = .standard, log: any CommandLogging = CommandLog()) {
        self.host = host
        self.registry = registry
        self.log = log
    }

    /// Ответ одной строкой и ход — в `progress`.
    public func run(_ request: ControlRequest, progress: @escaping (ControlProgress) -> Void = { _ in }) async -> ControlResponse {
        let started = ContinuousClock.now
        let response = await execute(request, progress: progress)
        let elapsed = ContinuousClock.now - started
        log.record(CommandLogEntry(command: request.command, agent: request.agent, target: CommandLogEntry.target(of: request.args),
                                   errorCode: response.error?.code,
                                   durationMs: Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)))
        return response
    }

    /// Ответ строками для сокета: ход, затем итог.
    public func stream(_ request: ControlRequest) -> AsyncStream<ControlResponseLine> {
        AsyncStream { continuation in
            Task { @MainActor in
                let response = await self.run(request) { continuation.yield(.progress(id: request.id, $0)) }
                continuation.yield(.result(response))
                continuation.finish()
            }
        }
    }

    private func execute(_ request: ControlRequest, progress: @escaping (ControlProgress) -> Void) async -> ControlResponse {
        let context = SessionContext(host: host, progress: progress)
        do {
            let (spec, args, handler) = try prepare(request.command, request.args)
            var request = request
            request.command = spec.name
            let session = CommandSession(host: host, request: request, spec: spec, args: args, registry: registry, context: context)
            let result: CommandResult
            if spec.access == .write {
                await writeLock.acquire()
                defer { writeLock.release() }
                lastContext = context
                result = try await Self.write(session, handler)
            } else {
                result = try await handler(session)
            }
            return .success(request.id, result.data, warnings: context.warnings, text: result.text)
        } catch {
            return .failure(request.id, ControlError.wrapping(error), warnings: context.warnings)
        }
    }

    /// Запись одним шагом отмены; ошибка откатывает её целиком. Пакет сам делит отмену по шагам.
    static func write(_ session: CommandSession, _ handler: CommandHandler) async throws -> CommandResult {
        guard session.spec.name != ServiceHandlers.batchCommand else { return try await handler(session) }
        do {
            return try await session.context.grouped { try await handler(session) }
        } catch {
            session.context.rollBack()
            throw error
        }
    }

    /// Команда по каталогу, проверенные аргументы и обработчик — до выполнения (FR-408).
    func prepare(_ command: String, _ rawArgs: [String: ControlJSON]) throws(ControlError) -> (CommandSpec, [String: ControlJSON], CommandHandler) {
        let words = command.split(whereSeparator: { $0 == "." || $0 == " " }).map(String.init)
        guard let spec = CommandCatalog.spec(words: words) else {
            let near = CommandCatalog.suggestion(for: words)
            throw ControlError(.unknownCommand, "Нет команды «\(words.joined(separator: " "))»",
                               hint: near.map { "Похоже на: mynotion \($0.invocation)" } ?? "Список команд: mynotion --help",
                               details: near.map { ["suggestion": .string($0.invocation)] })
        }
        let args = try CommandCatalog.normalized(rawArgs, for: spec)
        guard let handler = registry.handler(for: spec.name) else {
            throw ControlError.notImplemented(stage: spec.stage, command: spec.invocation)
        }
        return (spec, args, handler)
    }
}

extension ControlError {
    /// Ошибка обработчика как ответ: свои коды — как есть, ошибки хранилища — понятным кодом, прочее — `internal`.
    static func wrapping(_ error: any Error) -> ControlError {
        if let error = error as? ControlError { return error }
        switch error as? NotesStoreError {
        case .pageNotFound(let id):
            return ControlError(.pageNotFound, "Страницы \(id.uuidString.lowercased()) нет", hint: "mynotion page tree",
                                details: ["pageId": .string(id.uuidString.lowercased())])
        case .blockNotFound(let id):
            return ControlError(.blockNotFound, "Блока \(id.uuidString.lowercased()) нет", hint: "id блоков: mynotion page read <стр> --format json",
                                details: ["blockId": .string(id.uuidString.lowercased())])
        default:
            break
        }
        return ControlError(.internal, "Сбой внутри приложения: \(error.localizedDescription)",
                            hint: "Подробности: log show --predicate 'category == \"control\"' --last 5m")
    }
}
