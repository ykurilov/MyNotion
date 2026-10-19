import Foundation
import GRDB
import NotesCore

/// Копия файла на этом Mac (data-model.md, «Attachment»): локальная таблица `attachment`, не синхронизируется.
public struct AttachmentRecord: Sendable, Hashable {
    public var id: UUID
    public var ref: AttachmentRef
    /// Путь относительно папки `Attachments/`; пусто — файла здесь ещё нет.
    public var localPath: String?
    public var state: AttachmentState
    public var uploadedParts: Set<Int>
    public var downloadedParts: Set<Int>
    /// Ни один блок не ссылается; стирание через 30 дней (research R10).
    public var orphanedAt: Date?
    /// Для надписи на заглушке.
    public var lastError: String?

    init(ref: AttachmentRef, localPath: String?, state: AttachmentState, orphanedAt: Date?) {
        id = ref.id
        self.ref = ref
        self.localPath = localPath
        self.state = state
        uploadedParts = []
        downloadedParts = []
        self.orphanedAt = orphanedAt
    }

    init?(row: Row) {
        guard let idText: String = row["id"], let id = UUID(uuidString: idText),
              let refText: String = row["ref"], let ref = try? JSONDecoder().decode(AttachmentRef.self, from: Data(refText.utf8)),
              let stateText: String = row["state"], let state = AttachmentState(rawValue: stateText) else { return nil }
        self.id = id
        self.ref = ref
        localPath = row["localPath"]
        self.state = state
        uploadedParts = Self.parts(row["uploadedParts"])
        downloadedParts = Self.parts(row["downloadedParts"])
        orphanedAt = row["orphanedAt"]
        lastError = row["lastError"]
    }

    func save(in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO attachment (id, ref, localPath, state, uploadedParts, downloadedParts, orphanedAt, lastError)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET ref = excluded.ref, localPath = excluded.localPath, state = excluded.state,
                uploadedParts = excluded.uploadedParts, downloadedParts = excluded.downloadedParts,
                orphanedAt = excluded.orphanedAt, lastError = excluded.lastError
            """, arguments: [id.attachmentKey, Self.json(ref), localPath, state.rawValue, Self.json(uploadedParts.sorted()),
                             Self.json(downloadedParts.sorted()), orphanedAt, lastError])
    }

    private static func parts(_ text: String?) -> Set<Int> {
        guard let text, let parts = try? JSONDecoder().decode([Int].self, from: Data(text.utf8)) else { return [] }
        return Set(parts)
    }

    static func json(_ value: some Encodable) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data("null".utf8), as: UTF8.self)
    }
}

/// Переходы (data-model.md): `local` → `uploading` → `uploaded`; на другом Mac `remote` → `downloading` → `uploaded`.
public enum AttachmentState: String, Sendable, Hashable {
    case local
    case uploading
    case uploaded
    case remote
    case downloading
    case failed
}

public enum AttachmentError: Error, Equatable, LocalizedError {
    /// Больше 100 МБ: блок не создаётся.
    case tooLarge(name: String)
    case cannotRead(String)
    /// После скачивания SHA-256 не сошёлся с описанием в блоке.
    case damaged

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "Файл больше 100 МБ — MyNotion такие не хранит"
        case .cannotRead(let reason): "Не удалось скопировать файл: \(reason)"
        case .damaged: "Файл пришёл с другого Mac повреждённым — попробую скачать ещё раз позже"
        }
    }
}

/// Что вид блока показывает вместо файла (contracts/blocks-and-keys.md, «Картинка»).
public enum AttachmentAvailability: Sendable, Hashable {
    /// Файл на этом Mac.
    case ready(URL)
    /// Качается или стоит в очереди.
    case downloading
    /// Другой Mac ещё не отправил файл на сервер.
    case waitingForOtherMac
    /// Скачать не вышло: надпись для заглушки.
    case failed(String)
}

extension UUID {
    /// Ключ строки `attachment`: id строчными буквами, как все id в базе.
    var attachmentKey: String { uuidString.lowercased() }
}
