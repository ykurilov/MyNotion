import Foundation
import GRDB
import NotesCore
import Sync

/// Сборщик сирот (research R10): файл стирается на Mac и командой `DELETE /files/{id}` на сервере, только когда он
/// сирота дольше 30 дней и все устройства знают удаление. Последнее значит: не осталось ни одной пометки удалённого
/// блока со ссылкой на файл — их стирает сборщик надгробий (001), когда удаление подтвердили все устройства.
/// Сервер держит стёртое ещё 30 дней в корзине и 14 дней в копиях.
public struct AttachmentCollector: Sendable {
    public static let orphanLifetime: TimeInterval = 30 * 86_400

    let attachments: AttachmentStore
    let now: @Sendable () -> Date

    public init(attachments: AttachmentStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.attachments = attachments
        self.now = now
    }

    /// Стереть, что пора. Без синхронизации (`transport` пуст) — только копии на Mac. Возвращает стёртые id.
    @discardableResult
    public func collect(transport: (any SyncFileTransport)?) async throws -> [UUID] {
        var erased: [UUID] = []
        for record in try due() {
            // Сначала сервер: без связи копия остаётся до следующего раза, на сервере ничего не повисает.
            try await transport?.deleteFile(record.id)
            try attachments.erase(record.id)
            erased.append(record.id)
        }
        return erased
    }

    /// Есть ли что стирать — дёшево, для решения, запускать ли очередь файлов.
    public func hasDue() throws -> Bool {
        try !due().isEmpty
    }

    private func due() throws -> [AttachmentRecord] {
        try attachments.records(sql: """
            SELECT * FROM attachment WHERE orphanedAt IS NOT NULL AND orphanedAt <= ?
                AND NOT EXISTS (SELECT 1 FROM block WHERE instr(upper(block.props), upper(attachment.id)) > 0)
                AND NOT EXISTS (SELECT 1 FROM page WHERE page.cover IS NOT NULL AND instr(upper(page.cover), upper(attachment.id)) > 0)
            ORDER BY id
            """, arguments: [now().addingTimeInterval(-Self.orphanLifetime)])
    }
}
