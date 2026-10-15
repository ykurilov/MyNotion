import AppKit

/// Флаги командной строки приложения (README, «Флаги запуска»).
struct LaunchOptions {
    /// `--database <путь>`: база вместо основной.
    var databaseURL: URL?
    /// `--generate-reference-library <путь>`: создать эталонную базу и выйти.
    var referenceLibraryURL: URL?
    /// `--generate-visual-sample`: добавить в открытую базу страницу «MyNotion — образец».
    var generatesVisualSample = false
    /// `--launch-report <путь>`: записать время запуска и память в покое.
    var launchReportURL: URL?
    /// `--window-snapshot <путь>`: когда страница готова, снять окно в PNG и выйти (снимок не требует экрана).
    var windowSnapshotURL: URL?
    /// `--typing-benchmark <путь>`: замер отклика набора, переходов и прокрутки (T048), отчёт в файл и выход.
    var typingBenchmarkURL: URL?
    /// `--hover-sidebar-row <номер>`: на снимке окна строка дерева с этим номером (с нуля) — как под мышью.
    var hoveredSidebarRow: Int?
    /// `--appearance light|dark`: тема окна вместо системной.
    var appearanceName: NSAppearance.Name?

    init(arguments: [String]) {
        var remaining = arguments.dropFirst()[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--database": databaseURL = remaining.popFirst().map(Self.fileURL)
            case "--generate-reference-library": referenceLibraryURL = remaining.popFirst().map(Self.fileURL)
            case "--generate-visual-sample": generatesVisualSample = true
            case "--launch-report": launchReportURL = remaining.popFirst().map(Self.fileURL)
            case "--window-snapshot": windowSnapshotURL = remaining.popFirst().map(Self.fileURL)
            case "--typing-benchmark": typingBenchmarkURL = remaining.popFirst().map(Self.fileURL)
            case "--hover-sidebar-row": hoveredSidebarRow = remaining.popFirst().flatMap { Int($0) }
            case "--appearance":
                switch remaining.popFirst() {
                case "light": appearanceName = .aqua
                case "dark": appearanceName = .darkAqua
                default: break
                }
            default: continue
            }
        }
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
