import ControlProtocol
import Foundation

/// Ссылка на страницу для чтения (006): `page share on|off|rotate|show`. Ссылки идут через сервер синхронизации.
public enum ShareHandlers {
    public static let all: [String: CommandHandler] = [
        "page.share": { session in
            let page = try session.page()
            guard let control = session.host.shareControl, control.isAvailable else {
                throw ControlError(.syncDisabled, "Ссылки работают через сервер синхронизации, а она на этом Mac выключена",
                                   hint: "Включить её можно только в окне: Настройки MyNotion → Синхронизация. Состояние: mynotion sync status")
            }
            let subpages = session.string("subpages").map { $0 == "on" }
            let state: ShareLinkState?
            do {
                switch session.string("action") {
                case "on": state = try await control.setShareLink(of: page.id, enabled: true, includeSubpages: subpages)
                case "off": state = try await control.setShareLink(of: page.id, enabled: false, includeSubpages: subpages)
                case "rotate": state = try await control.rotateShareLink(of: page.id)
                default: state = try await control.shareLink(of: page.id)
                }
            } catch let error as ControlError {
                throw error
            } catch {
                throw ControlError(.timeout, "Сервер ссылок не ответил: \(error.localizedDescription)",
                                   hint: "Проверить связь: mynotion sync status")
            }
            return CommandResult(ShareJSON.encode(state, page: page.id), text: ShareJSON.text(state))
        },
    ]
}

enum ShareJSON {
    static func encode(_ state: ShareLinkState?, page: UUID) -> ControlJSON {
        [
            "pageId": .string(page.controlText), "enabled": .bool(state?.enabled ?? false),
            "url": state.map { .string($0.url.absoluteString) } ?? .null,
            "includeSubpages": state.map { .bool($0.includeSubpages) } ?? .null,
            "published": .bool(state?.isPublished ?? false),
        ]
    }

    static func text(_ state: ShareLinkState?) -> String {
        guard let state else { return "– Ссылку ещё не включали" }
        guard state.enabled else { return "– Доступ по ссылке выключен; при включении ссылка будет та же: \(state.url.absoluteString)" }
        return "✓ \(state.url.absoluteString)" + (state.includeSubpages ? " (с подстраницами)" : " (без подстраниц)")
            + (state.isPublished ? "" : " — страница ещё публикуется")
    }
}
