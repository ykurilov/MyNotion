import AppKit
import PageVersions
import ServiceLaunch

/// Флаги командной строки приложения (README, «Флаги запуска»).
struct LaunchOptions {
    /// `--database <путь>`: база вместо основной.
    var databaseURL: URL?
    /// `--generate-reference-library <путь>`: создать эталонную базу и выйти.
    var referenceLibraryURL: URL?
    /// `--generate-visual-sample`: добавить в открытую базу страницу «MyNotion — образец».
    var generatesVisualSample = false
    /// `--generate-rich-sample`: добавить в открытую базу «богатую» страницу на 1 000 блоков (quickstart.md) и открыть её.
    var generatesRichSample = false
    /// `--generate-003-sample`: добавить в открытую базу дополнения 003 (quickstart.md, «Эталон»; каждая история — свою часть).
    var generates003Sample = false
    /// `--launch-report <путь>`: записать время запуска и память в покое.
    var launchReportURL: URL?
    /// `--window-snapshot <путь>`: когда страница готова, снять окно в PNG и выйти (снимок не требует экрана).
    var windowSnapshotURL: URL?
    /// `--typing-benchmark <путь>`: замер отклика набора, переходов и прокрутки (T048), отчёт в файл и выход.
    var typingBenchmarkURL: URL?
    /// `--search-benchmark <путь>`: замер поиска — время от нажатия до выдачи на экране (T054), отчёт в файл и выход.
    var searchBenchmarkURL: URL?
    /// `--rich-memory-check <путь>`: память за 120 переходов между «богатыми» страницами (US3, T056), отчёт в файл и выход.
    var richMemoryCheckURL: URL?
    /// `--tabs-benchmark <путь>`: замер вкладок — переключение, «назад», «вперёд», память 20 вкладок (US3, T056),
    /// отчёт в файл; в конце оставляет в базе 10 вкладок для замера запуска с ними, и выход.
    var tabsBenchmarkURL: URL?
    /// `--export-markdown <папка>`: выгрузить все записи в Markdown в эту папку без окна выбора и выйти (T057).
    var exportMarkdownURL: URL?
    /// `--import-notion <путь>`: импортировать выгрузку Notion (ZIP или папку) без окна выбора, напечатать отчёт и выйти (T090).
    var importNotionURL: URL?
    /// `--hover-sidebar-row <номер>`: на снимке окна строка дерева с этим номером (с нуля) — как под мышью.
    var hoveredSidebarRow: Int?
    /// `--appearance light|dark`: тема окна вместо системной.
    var appearanceName: NSAppearance.Name?
    /// `--ui-gallery <папка>`: на временной базе снять все состояния интерфейса в PNG и выйти.
    var uiGalleryURL: URL?
    /// `--ui-gallery-only <часть имени>`: снять только состояния, в имени которых есть эта строка.
    var uiGalleryFilter: String?
    /// Живая проверка синхронизации двумя экземплярами (`--sync-server`, `--sync-connect-token-file`,
    /// `--sync-write-join-code`, `--sync-join-code-file`): подключение без окна настроек.
    var syncAutomation: SyncAutomation.Options?
    /// `--reminders-clock-offset <секунды>`: часы напоминаний приложения сдвинуты вперёд — проверка «пропущенное
    /// во сне показывается сразу» без настоящего ожидания (UI-тесты US3).
    var remindersClockOffset: TimeInterval = 0
    /// `--reminder-latency-check <путь>`: живой замер опоздания напоминания (SC-104), итог в файл и выход.
    var reminderLatencyURL: URL?
    /// `--video-memory-check <путь>`: живой замер памяти YouTube (T098), итог в файл и выход.
    var videoMemoryURL: URL?
    /// `--versions-quick`: версии пишутся через 1 с тишины и не чаще раза в 2 с — UI-тест истории без минутных ожиданий.
    var versionTiming = PageVersionRecorder.Timing.standard
    /// `--generate-versions-sample`: только страница «Замер: история версий» с 200 версиями (UI-тест US6).
    var generatesVersionsSample = false
    /// Служебный запуск — в фоне: не забирает фокус и не всплывает.
    let presence: LaunchPresence

    /// Связываться с сервером синхронизации: не в галерее, замерах отклика и снимках. Замер запуска и памяти
    /// (`--launch-report`) синхронизацию не выключает: на базе, где она включена, мерится память с ней
    /// (`scripts/vm/sync-memory-check.sh`); у эталонной базы синхронизации нет.
    var allowsSync: Bool {
        uiGalleryURL == nil && typingBenchmarkURL == nil && searchBenchmarkURL == nil && windowSnapshotURL == nil
            && richMemoryCheckURL == nil
            && exportMarkdownURL == nil && tabsBenchmarkURL == nil
    }

    init(arguments: [String]) {
        presence = LaunchPresence(arguments: arguments)
        var remaining = arguments.dropFirst()[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--database": databaseURL = remaining.popFirst().map(Self.fileURL)
            case "--generate-reference-library": referenceLibraryURL = remaining.popFirst().map(Self.fileURL)
            case "--generate-visual-sample": generatesVisualSample = true
            case "--generate-rich-sample": generatesRichSample = true
            case "--generate-003-sample": generates003Sample = true
            case "--generate-versions-sample": generatesVersionsSample = true
            case "--versions-quick": versionTiming = PageVersionRecorder.Timing(minimumInterval: 2, quietPeriod: 1)
            case "--launch-report": launchReportURL = remaining.popFirst().map(Self.fileURL)
            case "--window-snapshot": windowSnapshotURL = remaining.popFirst().map(Self.fileURL)
            case "--typing-benchmark": typingBenchmarkURL = remaining.popFirst().map(Self.fileURL)
            case "--search-benchmark": searchBenchmarkURL = remaining.popFirst().map(Self.fileURL)
            case "--rich-memory-check": richMemoryCheckURL = remaining.popFirst().map(Self.fileURL)
            case "--tabs-benchmark": tabsBenchmarkURL = remaining.popFirst().map(Self.fileURL)
            case "--export-markdown": exportMarkdownURL = remaining.popFirst().map(Self.fileURL)
            case "--import-notion": importNotionURL = remaining.popFirst().map(Self.fileURL)
            case "--ui-gallery": uiGalleryURL = remaining.popFirst().map(Self.fileURL)
            case "--ui-gallery-only": uiGalleryFilter = remaining.popFirst()
            case "--hover-sidebar-row": hoveredSidebarRow = remaining.popFirst().flatMap { Int($0) }
            case "--reminder-latency-check": reminderLatencyURL = remaining.popFirst().map(Self.fileURL)
            case "--video-memory-check": videoMemoryURL = remaining.popFirst().map(Self.fileURL)
            case "--reminders-clock-offset": remindersClockOffset = remaining.popFirst().flatMap { TimeInterval($0) } ?? 0
            case "--sync-server": syncAutomation = (syncAutomation ?? .init()).with { $0.serverAddress = remaining.popFirst() }
            case "--sync-connect-token-file":
                syncAutomation = (syncAutomation ?? .init()).with { $0.tokenFile = remaining.popFirst().map(Self.fileURL) }
            case "--sync-write-join-code":
                syncAutomation = (syncAutomation ?? .init()).with { $0.joinCodeOutput = remaining.popFirst().map(Self.fileURL) }
            case "--sync-join-code-file":
                syncAutomation = (syncAutomation ?? .init()).with { $0.joinCodeInput = remaining.popFirst().map(Self.fileURL) }
            case "--sync-log": syncAutomation = (syncAutomation ?? .init()).with { $0.logFile = remaining.popFirst().map(Self.fileURL) }
            case "--sync-device-name": syncAutomation = (syncAutomation ?? .init()).with { $0.deviceName = remaining.popFirst() }
            case "--appearance":
                switch remaining.popFirst() {
                case "light": appearanceName = .aqua
                case "dark": appearanceName = .darkAqua
                default: break
                }
            default: continue
            }
        }
        if uiGalleryURL != nil {
            // Галерея пишет в базу (набор «/», очистка корзины): только своя временная база, не основная.
            databaseURL = FileManager.default.temporaryDirectory.appending(path: "MyNotion-gallery-\(UUID().uuidString).sqlite")
        }
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
