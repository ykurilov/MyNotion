import Foundation

/// Запуск приложения: подменяется в тестах.
public protocol AppLaunching: Sendable {
    func isAppRunning() -> Bool
    func launch() throws
}

/// Своё приложение: пакет, в котором лежит сама команда (`MyNotion.app/Contents/Helpers/mynotion`, R8). Без AppKit.
public struct SystemAppLauncher: AppLaunching {
    public static let bundleIdentifier = "cloud.kurilov.mynotion"
    public static let processName = "MyNotion"

    let bundleURL: URL?

    public init(executable: URL = URL(fileURLWithPath: CommandLine.arguments[0])) {
        bundleURL = Self.bundleURL(forExecutable: executable)
    }

    /// Пакет `.app` над `Contents/Helpers` после разыменования ссылки; `nil` — команда лежит не в пакете.
    public static func bundleURL(forExecutable executable: URL) -> URL? {
        let resolved = executable.resolvingSymlinksInPath()
        let helpers = resolved.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents", bundle.pathExtension == "app" else {
            return nil
        }
        return bundle
    }

    public func isAppRunning() -> Bool {
        (try? Self.run("/usr/bin/pgrep", ["-x", Self.processName])) == 0
    }

    /// `open -g`: в фоне, без захвата фокуса. Команда не в пакете — приложение по идентификатору.
    public func launch() throws {
        let arguments = bundleURL.map { ["-g", $0.path] } ?? ["-g", "-b", Self.bundleIdentifier]
        let status = try Self.run("/usr/bin/open", arguments)
        guard status == 0 else { throw LaunchFailure(status: status) }
    }

    struct LaunchFailure: Error, LocalizedError {
        let status: Int32
        var errorDescription: String? { "open завершился с кодом \(status)" }
    }

    private static func run(_ path: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
