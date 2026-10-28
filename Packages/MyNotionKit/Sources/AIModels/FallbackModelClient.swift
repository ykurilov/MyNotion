import Foundation
import Synchronization

/// Чат видит модели только через этот протокол: в тестах и галерее — подменная модель.
public protocol ChatModelClient: Sendable {
    func stream(_ request: ModelRequest, model: ChatModel) -> AsyncThrowingStream<ModelStreamEvent, Error>
}

/// Пути модели по очереди. Следующий путь пробуется, только пока модель не начала отвечать:
/// сбой связи или сервера, 429, молчание дольше `firstTokenTimeout`, нет ключа основного поставщика.
/// После сбоя поставщик пропускается `skipFailedFor` — чтобы каждый запрос не ждал заново.
public final class FallbackModelClient: ChatModelClient {
    private let routes: ModelRouteClient
    private let firstTokenTimeout: Duration
    private let skipFailedFor: TimeInterval
    private let now: @Sendable () -> Date
    private let failedUntil = Mutex<[ModelProvider: Date]>([:])

    public init(routes: ModelRouteClient, firstTokenTimeout: Duration = .seconds(25), skipFailedFor: TimeInterval = 120,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.routes = routes
        self.firstTokenTimeout = firstTokenTimeout
        self.skipFailedFor = skipFailedFor
        self.now = now
    }

    public func stream(_ request: ModelRequest, model: ChatModel) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, model: model, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: ModelRequest, model: ChatModel,
                     continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation) async throws {
        let candidates = routesToTry(model)
        var lastError: Error = ModelError.badResponse
        for (position, route) in candidates.enumerated() {
            let isLast = position == candidates.count - 1
            do {
                try await attempt(request, route: route, continuation: continuation)
                return
            } catch let failure as AttemptFailure {
                try Task.checkCancellation()
                guard !failure.started, let error = failure.error as? ModelError, error.allowsFallback, !isLast else { throw failure.error }
                // Ключ Юрий может добавить в любую минуту — пропускать поставщика незачем.
                if case .missingKey = error {} else { markFailed(route.provider) }
                lastError = error
            }
        }
        throw lastError
    }

    /// Поставщики, у которых недавно был сбой, — в конец очереди, а не прочь: другого пути может не быть.
    private func routesToTry(_ model: ChatModel) -> [ModelRoute] {
        let moment = now()
        let failed = failedUntil.withLock { $0.filter { $0.value > moment }.keys }
        let healthy = model.routes.filter { !failed.contains($0.provider) }
        return healthy.isEmpty ? model.routes : healthy
    }

    private func markFailed(_ provider: ModelProvider) {
        let until = now().addingTimeInterval(skipFailedFor)
        failedUntil.withLock { $0[provider] = until }
    }

    private struct AttemptFailure: Error {
        let error: Error
        let started: Bool
    }

    /// События до первого кусочка ответа копятся: если путь сорвётся, чат их не увидит.
    private func attempt(_ request: ModelRequest, route: ModelRoute,
                         continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation) async throws {
        let started = Mutex(false)
        let timedOut = Mutex(false)
        let reader = Task {
            var pending: [ModelStreamEvent] = []
            for try await event in routes.stream(request, route: route) {
                if started.withLock({ $0 }) {
                    continuation.yield(event)
                } else if event.isContent {
                    started.withLock { $0 = true }
                    pending.forEach { continuation.yield($0) }
                    pending = []
                    continuation.yield(event)
                } else {
                    pending.append(event)
                }
            }
            // Поток, отменённый сторожем, просто кончается: его начало чату не нужно.
            if !Task.isCancelled { pending.forEach { continuation.yield($0) } }
        }
        let timeout = firstTokenTimeout
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            if !started.withLock({ $0 }) {
                timedOut.withLock { $0 = true }
                reader.cancel()
            }
        }
        defer { watchdog.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await reader.value
            } onCancel: {
                reader.cancel()
            }
        } catch {
            if timedOut.withLock({ $0 }) { throw AttemptFailure(error: ModelError.timeout, started: false) }
            throw AttemptFailure(error: error, started: started.withLock { $0 })
        }
        if timedOut.withLock({ $0 }) { throw AttemptFailure(error: ModelError.timeout, started: false) }
    }
}
