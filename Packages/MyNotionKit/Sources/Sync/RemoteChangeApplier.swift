import Foundation
import NotesCore

/// Пачка из журнала сервера после расшифровки.
public struct ReceivedBatch: Sendable {
    public let seq: Int
    public let batchId: String
    public let batch: SyncBatch

    public init(seq: Int, batchId: String, batch: SyncBatch) {
        self.seq = seq
        self.batchId = batchId
        self.batch = batch
    }
}

/// Применяет пришедшие пачки (T076, research R4, R5). Сначала записывает открытые страницы — набранное ложится
/// в базу со своими метками, и слияние видит его; затем каждая пачка — своя транзакция вместе с номером
/// применённого; в конце открытые страницы принимают пришедшее без перечитывания и без сдвига курсора.
@MainActor
public final class RemoteChangeApplier {
    public let store: NotesStore
    public let openDocuments: OpenDocuments?
    public let merger: ChangeMerger
    /// После применения: что поменялось и о чём сказать Юрию.
    public var onApplied: ((MergeReport) -> Void)?

    public init(store: NotesStore, openDocuments: OpenDocuments?, localDeviceName: String) {
        self.store = store
        self.openDocuments = openDocuments
        merger = ChangeMerger(localDeviceName: localDeviceName)
    }

    @discardableResult
    public func apply(_ batches: [ReceivedBatch]) throws -> MergeReport {
        guard !batches.isEmpty else { return MergeReport() }
        openDocuments?.saveAll()
        var report = MergeReport()
        defer { deliver(report) }
        for received in batches {
            report += try store.write { transaction in
                let merged = try merger.apply(received.batch, in: transaction)
                try SyncAccountStore.recordPulled(seq: received.seq, in: transaction.database)
                return merged
            }
        }
        return report
    }

    /// Снимок с сервера (журнал до него сжат).
    @discardableResult
    public func apply(_ snapshot: SyncSnapshot) throws -> MergeReport {
        openDocuments?.saveAll()
        let report = try store.write { transaction in
            let merged = try merger.apply(snapshot, in: transaction)
            try SyncAccountStore.recordPulled(seq: snapshot.seq, in: transaction.database)
            return merged
        }
        try SyncAccountStore(store: store).recordSnapshot(seq: snapshot.seq)
        deliver(report)
        return report
    }

    private func deliver(_ report: MergeReport) {
        guard !report.touchedPageIds.isEmpty || !report.notices.isEmpty else { return }
        if let openDocuments {
            openDocuments.applyExternalChanges(toPages: report.touchedPageIds.intersection(openDocuments.openPageIds))
        }
        onApplied?(report)
    }
}
