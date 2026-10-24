import Foundation
import NotionImport

/// Импорт в окне и синхронизация приложения (этап 7): `App/Control/AppTransferControl.swift`. Сам импорт и выгрузку
/// делают обработчики команд теми же `NotionImporter` и `MarkdownExporter`, что меню; приложение показывает ход импорта
/// карточкой окна и отвечает за синхронизацию.
@MainActor
public protocol TransferControl: AnyObject {
    /// Идёт импорт — из меню или командой (`app status`; второй импорт не начинается).
    var isImporting: Bool { get }
    /// Импорт командой начался: карточка хода в окне, как у импорта из меню; её «Остановить» вызывает `stop`.
    func commandImportDidStart(stop: @escaping @MainActor () -> Void)
    func commandImport(progress: NotionImportProgress)
    /// Импорт кончился: карточка убирается. Отчёт получает агент — окно итога не открывается, страница Юрия остаётся на месте.
    func commandImportDidFinish(_ outcome: Result<NotionImportReport, any Error>)
    /// Состояние синхронизации — то же, что у значка внизу боковой панели.
    var syncState: SyncState { get }
    /// Отправить и получить сейчас; ответ — когда круг прошёл или вышел срок ожидания.
    func syncNow() async throws -> SyncState
}

/// Состояние синхронизации для `sync status` и `sync now`.
public struct SyncState: Sendable, Hashable {
    public enum Status: String, Sendable {
        /// Синхронизация не включена на этом Mac.
        case off
        /// Всё отправлено, свежие правки других Mac получены.
        case ready
        /// Есть неотправленные правки, идёт отправка.
        case sending
        /// Что-то мешает; правки ждут в очереди.
        case error
    }

    public var status: Status
    /// Текст значка: «На всех ваших Mac одни и те же записи.», текст помехи.
    public var detail: String?
    public var lastSyncedAt: Date?
    /// Имя этого Mac для синхронизации.
    public var deviceName: String?

    public init(status: Status, detail: String? = nil, lastSyncedAt: Date? = nil, deviceName: String? = nil) {
        self.status = status
        self.detail = detail
        self.lastSyncedAt = lastSyncedAt
        self.deviceName = deviceName
    }

    public var isEnabled: Bool { status != .off }
}
