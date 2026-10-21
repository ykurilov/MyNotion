import Foundation
import Formulas
import NotesCore

/// «Живые» формулы — с `now()` или `today()` (FR-323): пересчитываются раз в минуту только у открытых видов и при
/// открытии вида. Закрытые базы не трогаются: их итог обновится, когда вид откроют.
@MainActor
public final class LiveFormulaClock {
    public let queue: FormulaRecomputeQueue
    private var openCounts: [UUID: Int] = [:]
    private var timer: Timer?

    public init(queue: FormulaRecomputeQueue) {
        self.queue = queue
    }

    /// Открытые базы.
    public var openDatabases: Set<UUID> { Set(openCounts.keys) }

    /// Вид базы открыт: «живые» итоги — сразу, дальше раз в минуту.
    public func viewOpened(_ databaseId: UUID) {
        openCounts[databaseId, default: 0] += 1
        if openCounts[databaseId] == 1 { recomputeLive(databaseId) }
    }

    public func viewClosed(_ databaseId: UUID) {
        guard let count = openCounts[databaseId] else { return }
        openCounts[databaseId] = count > 1 ? count - 1 : nil
    }

    /// Часы раз в минуту (в приложении); тесты зовут `tick()` сами.
    public func start(interval: TimeInterval = 60) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 5
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Минута прошла: «живые» формулы открытых баз.
    public func tick() {
        for databaseId in openCounts.keys { recomputeLive(databaseId) }
    }

    private func recomputeLive(_ databaseId: UUID) {
        let live = (try? DatabaseCatalog.read(databaseId, in: queue.store))?.properties.filter { property in
            property.kind == .formula && ((property.config["expression"]?.string).flatMap { try? FormulaParser.parse($0) }?.isLive ?? false)
        } ?? []
        guard !live.isEmpty else { return }
        queue.enqueue(databaseId, propertyIds: Set(live.map(\.id)))
    }
}
