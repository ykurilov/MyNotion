import ControlProtocol
import Foundation

/// Вся команда `mynotion` без `main`: строка → код выхода. Вывод — через `out`/`err`, чтобы проверять тестами.
public enum MyNotionCLI {
    public static func run(_ argv: [String], launcher: any AppLaunching = SystemAppLauncher(),
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           currentDirectory: String = FileManager.default.currentDirectoryPath,
                           out: (String) -> Void, err: (String) -> Void) -> Int32 {
        let invocation: Invocation
        do {
            invocation = try CommandCatalog.parse(argv, environment: environment, currentDirectory: currentDirectory) { source in
                try readContent(source, currentDirectory: currentDirectory)
            }
        } catch {
            // Разбор не дошёл до настроек: `--human` ищется в самой строке.
            return print(.failure(UUID().uuidString, error), human: argv.contains("--human"), out: out, err: err)
        }

        switch invocation {
        case .help(let text):
            out(text + "\n")
            return 0
        case .version(let settings):
            return printVersion(settings, launcher: launcher, out: out, err: err)
        case .request(let request, let settings, let spec) where spec.runsWithoutApp:
            return print(local(request), human: settings.human, out: out, err: err)
        case .request(let request, let settings, _):
            let response = CommandRunner(launcher: launcher).run(request, settings: settings) { progress in
                guard settings.human else { return }
                err("… \(progress.done)" + (progress.total.map { " из \($0)" } ?? "") + (progress.stage.map { " — \($0)" } ?? "") + "\n")
            }
            return print(response, human: settings.human, out: out, err: err)
        }
    }

    /// Команды без приложения: пока только `commands`.
    static func local(_ request: ControlRequest) -> ControlResponse {
        guard request.command == "commands" else {
            return .failure(request.id, ControlError(.internal, "Команда «\(request.command)» не выполняется без приложения"))
        }
        if request.args["json"] == true {
            return .success(request.id, CommandCatalog.json)
        }
        let width = CommandCatalog.all.map(\.invocation.count).max() ?? 0
        let text = CommandCatalog.all.map { "\($0.invocation.padding(toLength: width + 2, withPad: " ", startingAt: 0))\($0.summary)" }
            .joined(separator: "\n")
        return .success(request.id, CommandCatalog.json, text: text)
    }

    static func print(_ response: ControlResponse, human: Bool, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        if human {
            if response.ok {
                out(HumanOutput.success(response))
            } else if let error = response.error {
                err(HumanOutput.failure(error))
            }
            err(HumanOutput.warnings(response))
        } else {
            out(json(response))
        }
        return ExitCode.of(response)
    }

    static func json(_ response: ControlResponse) -> String {
        var plain = response
        plain.text = nil
        let data = (try? ControlCoding.encoder.encode(plain)) ?? Data(#"{"ok":false}"#.utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// `--version`: версия команды (из пакета, где она лежит) и, если приложение уже идёт, — его.
    static func printVersion(_ settings: ClientSettings, launcher: any AppLaunching, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        var noLaunch = settings
        noLaunch.noLaunch = true
        noLaunch.launchTimeout = 0
        let status = CommandRunner(launcher: launcher).run(ControlRequest(command: "app.status", timeoutMs: 3_000), settings: noLaunch)
        var data: [String: ControlJSON] = ["protocol": .number(Double(ControlProtocolVersion.current)),
                                           "client": clientVersion.map(ControlJSON.string) ?? .null]
        data["app"] = status.ok ? status.data?["version"] ?? .null : .null
        let text = "mynotion \(clientVersion ?? "?"), протокол \(ControlProtocolVersion.current)"
            + (status.ok ? ", приложение \(status.data?["version"]?.string ?? "?")" : ", приложение не запущено")
        return print(.success(UUID().uuidString, .object(data), text: text), human: settings.human, out: out, err: err)
    }

    static var clientVersion: String? {
        guard let bundle = SystemAppLauncher.bundleURL(forExecutable: URL(fileURLWithPath: CommandLine.arguments[0])),
              let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// Содержимое `--markdown`, `--file`: `-` — stdin, иначе файл (относительный путь — от текущей папки).
    static func readContent(_ source: String, currentDirectory: String) throws -> String {
        let data: Data
        if source == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            let url = source.hasPrefix("/") ? URL(fileURLWithPath: source)
                : URL(fileURLWithPath: currentDirectory, isDirectory: true).appendingPathComponent(source)
            data = try Data(contentsOf: url)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
