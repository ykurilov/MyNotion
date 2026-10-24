import ControlProtocol
import Foundation

/// Служебные команды (этап 1): состояние приложения, каталог, пакет.
public enum ServiceHandlers {
    static let batchCommand = "batch"

    public static let all: [String: CommandHandler] = [
        "app.status": appStatus,
        "commands": { _ in CommandResult(CommandCatalog.json, text: "\(CommandCatalog.all.count) команд: mynotion commands --json") },
        batchCommand: { session in try await BatchRunner(session: session).run() },
    ]

    static let appStatus: CommandHandler = { session in
        let info = session.host.appInfo
        let windows = session.host.windowControl.windows()
        let importing = session.host.transferControl?.isImporting ?? false
        let data: ControlJSON = [
            "protocol": .number(Double(ControlProtocolVersion.current)),
            "version": .string(info.version),
            "build": .string(info.build),
            "database": .string(info.databasePath),
            "socket": .string(info.socketPath),
            "windows": .array(windows.map(WindowJSON.encode)),
            "importing": .bool(importing),
        ]
        let text = "✓ MyNotion \(info.version) (\(info.build)), протокол \(ControlProtocolVersion.current), окон: \(windows.count)"
            + (importing ? ", идёт импорт" : "") + "\nБаза: \(info.databasePath)"
        return CommandResult(data, text: text)
    }
}

/// Окна и вкладки в ответе (`app status`, команды окна).
public enum WindowJSON {
    public static func encode(_ window: WindowInfo) -> ControlJSON {
        [
            "index": .number(Double(window.index)), "front": .bool(window.isFront), "canGoBack": .bool(window.canGoBack),
            "canGoForward": .bool(window.canGoForward), "busy": .bool(window.isBusy),
            "tabs": .array(window.tabs.map { tab in
                ["index": .number(Double(tab.index)), "pageId": ControlJSON(tab.pageId), "title": .string(tab.title),
                 "selected": .bool(tab.isSelected)]
            }),
        ]
    }
}
