import Foundation

/// Флаги запуска для снимков в симуляторе и живой проверки синхронизации (`xcrun simctl launch … <флаги>`).
/// Обычный запуск с экрана iPhone их не передаёт.
struct PhoneLaunchOptions {
    /// `--database <путь>`: своя база вместо базы в папке приложения.
    var databaseURL: URL?
    /// `--sample-pages`: в пустую базу — несколько страниц с иконками и подстраницами для снимков.
    var addsSamplePages = false
    /// `--screen connect|settings|page:<название>`: сразу открыть экран.
    var initialScreen: InitialScreen?
    /// `--sync-server <адрес>`: свой сервер синхронизации (локальный — для живой проверки).
    var syncServer: String?
    /// `--sync-device-name <имя>`.
    var syncDeviceName: String?
    /// `--sync-join-code-file <путь>`: подключиться кодом из файла, когда он появится.
    var joinCodeFile: URL?
    /// `--sync-log <путь>`: ход синхронизации и живой проверки.
    var syncLog: URL?
    /// `--live-check-page <название>` и `--live-check-edit <текст>`: дождаться страницы с Mac и дописать в неё абзац.
    var liveCheckPageTitle: String?
    var liveCheckEdit: String?

    enum InitialScreen: Equatable {
        case connect
        case settings
        case page(title: String)
    }

    static func parse(_ arguments: [String]) -> PhoneLaunchOptions {
        var options = PhoneLaunchOptions()
        var remaining = arguments.dropFirst()
        while let argument = remaining.popFirst() {
            switch argument {
            case "--database": options.databaseURL = remaining.popFirst().map { URL(fileURLWithPath: $0) }
            case "--sample-pages": options.addsSamplePages = true
            case "--screen":
                switch remaining.popFirst() {
                case "connect": options.initialScreen = .connect
                case "settings": options.initialScreen = .settings
                case let value? where value.hasPrefix("page:"): options.initialScreen = .page(title: String(value.dropFirst(5)))
                default: break
                }
            case "--sync-server": options.syncServer = remaining.popFirst()
            case "--sync-device-name": options.syncDeviceName = remaining.popFirst()
            case "--sync-join-code-file": options.joinCodeFile = remaining.popFirst().map { URL(fileURLWithPath: $0) }
            case "--sync-log": options.syncLog = remaining.popFirst().map { URL(fileURLWithPath: $0) }
            case "--live-check-page": options.liveCheckPageTitle = remaining.popFirst()
            case "--live-check-edit": options.liveCheckEdit = remaining.popFirst()
            default: break
            }
        }
        return options
    }
}
