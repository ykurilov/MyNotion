import ControlProtocol
import Foundation

/// Окна, вкладки, «назад/вперёд» (этап 6, US5). Номера окон и вкладок проверяются здесь по `windows()`, само действие
/// делает `WindowControl` приложения. Окна на передний план сами не выходят: только `open --activate`.
public enum WindowHandlers {
    public static let all: [String: CommandHandler] = [
        "window.state": windowState,
        "open": open,
        "tab.new": { session in
            let window = try session.targetWindow()
            return answer(try session.host.windowControl.newTab(window: window.index), "Новая вкладка")
        },
        "tab.select": { session in
            let window = try session.targetWindow()
            let tab = try session.existingTab(in: window, argument: session.int("tab"))
            return answer(try session.host.windowControl.selectTab(tab, window: window.index), "Вкладка \(tab) выбрана")
        },
        "tab.close": { session in
            let window = try session.targetWindow()
            let tab = try session.existingTab(in: window, argument: session.int("tab"))
            guard window.tabs.count > 1 else {
                throw ControlError(.invalidArgument, "Вкладка \(tab) — последняя в окне \(window.index)",
                                   hint: "Команды закрыть окно нет. Открыть другую страницу в этой вкладке: mynotion open <страница>",
                                   details: ["argument": "tab"])
            }
            return answer(try session.host.windowControl.closeTab(tab, window: window.index), "Вкладка \(tab) закрыта")
        },
        "tab.reopen": { session in
            let window = try session.targetWindow()
            guard window.canReopenTab else {
                throw ControlError(.tabNotFound, "В окне \(window.index) нет закрытых вкладок",
                                   hint: "Закрытые вкладки помнятся, пока окно открыто: mynotion window state", details: ["window": .number(Double(window.index))])
            }
            return answer(try session.host.windowControl.reopenTab(window: window.index), "Вкладка возвращена")
        },
        "nav.back": { session in
            let window = try session.targetWindow()
            guard window.canGoBack else { return stayed(window, "Назад идти некуда") }
            return answer(try session.host.windowControl.back(window: window.index), "Назад", moved: true)
        },
        "nav.forward": { session in
            let window = try session.targetWindow()
            guard window.canGoForward else { return stayed(window, "Вперёд идти некуда") }
            return answer(try session.host.windowControl.forward(window: window.index), "Вперёд", moved: true)
        },
    ]

    static let windowState: CommandHandler = { session in
        let windows = session.host.windowControl.windows()
        let front = windows.first(where: \.isFront)?.index
        let text = windows.isEmpty ? "Окон нет. Открыть: mynotion open <страница>"
            : windows.map { "Окно \($0.index)\($0.isFront ? " (переднее)" : ""): " + $0.tabs.map(tabText).joined(separator: " | ") }.joined(separator: "\n")
        return CommandResult(["windows": .array(windows.map(WindowJSON.encode)), "front": front.map { .number(Double($0)) } ?? .null], text: text)
    }

    static let open: CommandHandler = { session in
        let page = try session.page()
        var blockId: UUID?
        if session.string("block") != nil { blockId = try session.block(inPage: page.id).id }
        let control = session.host.windowControl
        let windows = control.windows()
        // Окон нет (все закрыты) — страница открывается в новом окне, какие бы флаги ни были.
        let placement: OpenPlacement = session.flag("newWindow") || windows.isEmpty ? .newWindow : session.flag("newTab") ? .newTab : .current
        let target = placement == .newWindow ? nil : try session.targetWindow()
        let info = try await control.open(page.id, placement: placement, blockId: blockId, window: target?.index, activate: session.flag("activate"))
        let data: ControlJSON = ["page": ["id": .string(page.id.controlText), "title": .string(page.title)], "window": WindowJSON.encode(info)]
        return CommandResult(data, text: "✓ Открыто «\(page.title)» в окне \(info.index)")
    }

    private static func answer(_ info: WindowInfo, _ done: String, moved: Bool? = nil) -> CommandResult {
        var data: [String: ControlJSON] = ["window": WindowJSON.encode(info)]
        if let moved { data["moved"] = .bool(moved) }
        return CommandResult(.object(data), text: "✓ \(done): окно \(info.index), " + info.tabs.map(tabText).joined(separator: " | "))
    }

    /// «Назад» и «вперёд» без истории — не ошибка: окно осталось как было.
    private static func stayed(_ window: WindowInfo, _ reason: String) -> CommandResult {
        CommandResult(["window": WindowJSON.encode(window), "moved": false], text: "– \(reason)")
    }

    private static func tabText(_ tab: TabInfo) -> String {
        (tab.isSelected ? "▸" : "") + "\(tab.index) «\(tab.title.isEmpty ? "Недавние" : tab.title)»"
    }
}

extension CommandSession {
    /// Окно команды: `--window N` или переднее. Лист в окне — `window_busy`, окна нет — `window_not_found`.
    func targetWindow() throws(ControlError) -> WindowInfo {
        let windows = host.windowControl.windows()
        let window: WindowInfo
        if let number = int("window") {
            guard let named = windows.first(where: { $0.index == number }) else {
                throw ControlError(.windowNotFound, "Окна \(number) нет: сейчас окон — \(windows.count)", hint: "Номера окон: mynotion window state",
                                   details: ["window": .number(Double(number))])
            }
            window = named
        } else {
            guard let front = windows.first(where: \.isFront) ?? windows.first else {
                throw ControlError(.windowNotFound, "Окон нет", hint: "Открыть страницу в новом окне: mynotion open <страница>")
            }
            window = front
        }
        guard !window.isBusy else {
            throw ControlError(.windowBusy, "В окне \(window.index) открыт лист или диалог (импорт, настройки)",
                               hint: "Закончить действие в окне или дождаться конца; команды с данными работают и так",
                               details: ["window": .number(Double(window.index))])
        }
        return window
    }

    /// Вкладка из `--tab` (без неё — выбранная) в пределах окна.
    func existingTab(in window: WindowInfo, argument: Int?) throws(ControlError) -> Int {
        guard let number = argument ?? window.tabs.first(where: \.isSelected)?.index else {
            throw ControlError(.tabNotFound, "В окне \(window.index) нет вкладок", hint: "Номера вкладок: mynotion window state")
        }
        guard window.tabs.contains(where: { $0.index == number }) else {
            throw ControlError(.tabNotFound, "Вкладки \(number) нет: в окне \(window.index) их \(window.tabs.count)", hint: "Номера вкладок: mynotion window state",
                               details: ["tab": .number(Double(number)), "window": .number(Double(window.index))])
        }
        return number
    }
}
