import Foundation
import GRDB
import NotesCore

/// Сборщик надгробий (T079, data-model.md): пометки удалённых блоков и надгробия страниц нужны, пока их не получили
/// все устройства. Когда каждое подтвердило всё, что знает этот Mac, а очередь исходящих пуста, они стираются.
/// Без синхронизации ждать некого — стираются сразу.
public struct TombstoneCollector: Sendable {
    public let store: NotesStore

    public init(store: NotesStore) {
        self.store = store
    }

    /// `deviceAcks` — `lastAckSeq` всех активных устройств (`GET /devices`). `true` — стёрто.
    @discardableResult
    public func collect(deviceAcks: [Int]) throws -> Bool {
        try store.write { transaction in
            guard let account = try SyncAccountStore.account(in: transaction.database) else {
                try transaction.eraseDeletionMarksAndTombstones()
                return true
            }
            guard try Outbox.isEmpty(in: transaction.database), let slowest = deviceAcks.min(),
                  slowest >= max(account.lastPulledSeq, account.lastSentSeq) else { return false }
            try transaction.eraseDeletionMarksAndTombstones()
            return true
        }
    }

    /// Есть ли что стирать.
    public func hasMarks() throws -> Bool {
        try store.database.dbWriter.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM block WHERE isDeleted = 1) OR EXISTS (SELECT 1 FROM page_tombstone)
                """) ?? false
        }
    }
}
