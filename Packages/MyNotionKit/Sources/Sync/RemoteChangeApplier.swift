import AIChatHistory
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
    /// Ключи сервисов: победившие при слиянии ложатся в связку ключей после транзакции; `nil` — ключи не синхронизируются.
    public let serviceKeys: ServiceKeySync?
    /// Цикл синхронизации принимает ключи из пачек после подготовки (`ServiceKeySync.prepare`): до неё ключ из связки
    /// ключей без метки проиграл бы любому пришедшему. Пропущенные ключи устройство потом попросит у других.
    var acceptsServiceKeys = true
    /// После применения: что поменялось и о чём сказать Юрию.
    public var onApplied: ((MergeReport) -> Void)?

    public init(store: NotesStore, openDocuments: OpenDocuments?, localDeviceName: String, serviceKeys: ServiceKeySync? = nil) {
        self.store = store
        self.openDocuments = openDocuments
        self.serviceKeys = serviceKeys
        merger = ChangeMerger(localDeviceName: localDeviceName)
    }

    @discardableResult
    public func apply(_ batches: [ReceivedBatch]) throws -> MergeReport {
        guard !batches.isEmpty else { return MergeReport() }
        openDocuments?.saveAll()
        var report = MergeReport()
        var keys: [ServiceKeyChange] = []
        var chatsChanged = false
        defer {
            writeServiceKeys(keys)
            if chatsChanged { notifyChats() }
            deliver(report)
        }
        for received in batches {
            report += try store.write { transaction in
                var merged = try merger.apply(received.batch, in: transaction)
                let won = try ServiceKeys.merge(received.batch.serviceKeys, requestedByOthers: received.batch.requestsServiceKeys == true,
                                                names: acceptsServiceKeys ? serviceKeys?.keys.names : nil, in: transaction)
                if try AIChatSync.merge(received.batch.aiChats, requestedByOthers: received.batch.requestsAIChats == true,
                                        in: transaction) {
                    chatsChanged = true
                }
                try SyncAccountStore.recordPulled(seq: received.seq, in: transaction.database)
                keys += won
                merged.changedServiceKeys = Set(won.map(\.name))
                return merged
            }
        }
        return report
    }

    /// Снимок с сервера (журнал до него сжат).
    @discardableResult
    public func apply(_ snapshot: SyncSnapshot) throws -> MergeReport {
        openDocuments?.saveAll()
        var keys: [ServiceKeyChange] = []
        var chatsChanged = false
        let report = try store.write { transaction in
            var merged = try merger.apply(snapshot, in: transaction)
            keys = try ServiceKeys.merge(snapshot.serviceKeys, requestedByOthers: false,
                                         names: acceptsServiceKeys ? serviceKeys?.keys.names : nil, in: transaction)
            merged.changedServiceKeys = Set(keys.map(\.name))
            // Снимок старой версии без ключей: ключи из сжатой части журнала пропали — попросить другие устройства.
            if snapshot.serviceKeys == nil, serviceKeys != nil {
                try ServiceKeys.markForSending(requestingOthers: true, in: transaction.database)
            }
            // Снимок версии без чатов или с частью чатов: недостающие из сжатой части журнала попросить у других устройств.
            chatsChanged = try AIChatSync.mergeSnapshot(snapshot.aiChats, isComplete: snapshot.aiChatsPartial != true, in: transaction)
            try SyncAccountStore.recordPulled(seq: snapshot.seq, in: transaction.database)
            return merged
        }
        writeServiceKeys(keys)
        if chatsChanged { notifyChats() }
        try SyncAccountStore(store: store).recordSnapshot(seq: snapshot.seq)
        deliver(report)
        return report
    }

    /// Связка ключей — после коммита и не здесь: её отказ или вопрос macOS не держат ни пачку, ни окно.
    private func writeServiceKeys(_ changes: [ServiceKeyChange]) {
        guard let serviceKeys, !changes.isEmpty else { return }
        Task { await serviceKeys.writeReceived(changes) }
    }

    private func notifyChats() {
        NotificationCenter.default.post(name: AIChatStore.didChange, object: nil)
    }

    private func deliver(_ report: MergeReport) {
        guard !report.touchedPageIds.isEmpty || !report.notices.isEmpty || !report.changedServiceKeys.isEmpty else { return }
        if let openDocuments {
            openDocuments.applyExternalChanges(toPages: report.touchedPageIds.intersection(openDocuments.openPageIds))
        }
        onApplied?(report)
    }
}
