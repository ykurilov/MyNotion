import Attachments
import ControlProtocol
import Foundation
import NotesCore
import PageVersions

/// Что есть только у приложения (data-model.md, «Хост приложения»): хранилище, открытые документы, история, окна.
/// Тесты подставляют хост на временной базе.
@MainActor
public protocol ControlHost: AnyObject {
    var store: NotesStore { get }
    var attachments: AttachmentStore { get }
    var openDocuments: OpenDocuments { get }
    var versions: PageVersionStore { get }
    var versionRecorder: PageVersionRecorder { get }
    var windowControl: any WindowControl { get }
    /// Импорт, выгрузка, синхронизация (этап 7); `nil` — их нет (тесты).
    var transferControl: (any TransferControl)? { get }
    var appInfo: AppInfo { get }
    /// Часы команд: окно «до правки агента» (подменяются в тестах).
    var now: Date { get }
    /// Операция команды поменяла страницы дерева: панели и окна перечитывают их (как после правки в окне).
    func treeDidChange(_ pageIds: Set<UUID>)
    /// Иконка страницы сменилась: дерево и окна с этой страницей берут новую иконку, страница не перечитывается (курсор на месте).
    func iconDidChange(_ pageId: UUID)
    /// Обложка страницы сменилась: окна подставляют записанное, страница не перечитывается (курсор на месте).
    func appearanceDidChange(_ pageId: UUID)
    /// Запись прошла мимо открытых документов (Markdown целиком, импорт): шаг «после синхронизации» —
    /// `openDocuments.applyExternalChanges(toPages:)` и обновление окон.
    func refreshAfterDirectWrite(pages: Set<UUID>)
}

/// Сведения о приложении для `app status`.
public struct AppInfo: Sendable, Hashable {
    public var version: String
    public var build: String
    public var databasePath: String
    public var socketPath: String

    public init(version: String, build: String, databasePath: String, socketPath: String) {
        self.version = version
        self.build = build
        self.databasePath = databasePath
        self.socketPath = socketPath
    }
}

extension ControlHost {
    /// Хост без лёгкого пути (тесты): как любая правка дерева.
    public func iconDidChange(_ pageId: UUID) { treeDidChange([pageId]) }
    public func appearanceDidChange(_ pageId: UUID) { treeDidChange([pageId]) }
}
