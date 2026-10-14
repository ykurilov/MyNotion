import Foundation

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

    init(arguments: [String]) {
        var remaining = arguments.dropFirst()[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--database": databaseURL = remaining.popFirst().map(Self.fileURL)
            case "--generate-reference-library": referenceLibraryURL = remaining.popFirst().map(Self.fileURL)
            case "--generate-visual-sample": generatesVisualSample = true
            case "--launch-report": launchReportURL = remaining.popFirst().map(Self.fileURL)
            default: continue
            }
        }
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
