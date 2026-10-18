import CryptoKit
import Foundation
import GRDB
import NotesCore

/// Включение, подключение и выключение синхронизации (T080, FR-024). Без подключения ядро работает как прежде.
public enum SyncSetup {
    /// Синхронизация на этом Mac уже включена: после запуска приложения удалённое снова хранится пометками.
    public static func resume(store: NotesStore) throws -> SyncAccount? {
        let account = try SyncAccountStore(store: store).account()
        store.keepsDeletionMarks = account != nil
        return account
    }

    /// Записать подключение и положить в очередь все записи, что уже есть на этом Mac.
    public static func enable(store: NotesStore, account: SyncAccount) throws {
        try store.write { transaction in
            try SyncAccountStore.save(account, in: transaction.database)
            try transaction.database.execute(sql: "DELETE FROM outbox_entry")
            try Outbox.enqueueAllRecords(in: transaction)
        }
        store.keepsDeletionMarks = true
    }

    /// Выключить: подключение, очередь, токен и ключ удаляются; записи остаются. Пометкам удалённого ждать
    /// больше некого — они стираются.
    public static func disable(store: NotesStore, secrets: any SyncSecrets) throws {
        let account = try SyncAccountStore(store: store).account()
        try store.database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM sync_account; DELETE FROM outbox_entry;")
        }
        store.keepsDeletionMarks = false
        try TombstoneCollector(store: store).collect(deviceAcks: [])
        if let account { try secrets.delete(for: account.deviceId) }
    }

    /// Первый Mac: токен устройства, выданный командой `mynotion-sync bootstrap`. Ключ шифрования создаётся здесь.
    public static func connectFirstDevice(store: NotesStore, serverURL: URL, deviceToken: String, deviceName: String,
                                          secrets: any SyncSecrets, server: any SyncServer) async throws -> SyncAccount {
        let device = try await server.transport(deviceToken: deviceToken).currentDevice()
        try secrets.save(SyncSecretValues(deviceToken: deviceToken, encryptionKey: SymmetricKey(size: .bits256)), for: device.deviceId)
        let account = SyncAccount(serverURL: serverURL, deviceId: device.deviceId, deviceName: deviceName)
        try enable(store: store, account: account)
        return account
    }

    /// «Добавить Mac»: одноразовое приглашение сервера вместе с ключом шифрования.
    public static func makeJoinCode(transport: any SyncTransport, account: SyncAccount,
                                    secrets: any SyncSecrets) async throws -> JoinCode {
        guard let key = try secrets.load(for: account.deviceId)?.encryptionKey else { throw SyncSetupError.missingSecrets }
        return JoinCode(inviteCode: try await transport.invite().inviteCode, encryptionKey: key)
    }

    /// Второй и следующие Mac: код с экрана уже подключённого.
    public static func join(store: NotesStore, serverURL: URL, code: JoinCode, deviceName: String,
                            secrets: any SyncSecrets, server: any SyncServer) async throws -> SyncAccount {
        let joined = try await server.join(inviteCode: code.inviteCode, deviceName: deviceName)
        try secrets.save(SyncSecretValues(deviceToken: joined.deviceToken, encryptionKey: code.encryptionKey), for: joined.deviceId)
        let account = SyncAccount(serverURL: serverURL, deviceId: joined.deviceId, deviceName: deviceName)
        try enable(store: store, account: account)
        return account
    }
}

public enum SyncSetupError: Error, Equatable, LocalizedError {
    case missingSecrets

    public var errorDescription: String? {
        "Этот Mac забыл код подключения — выключите синхронизацию на нём и подключите его заново"
    }
}
