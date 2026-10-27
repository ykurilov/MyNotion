import ControlProtocol
import Foundation
import NotesCore

/// Щелчок по ссылке `mynotion://page/<id>` снаружи (чат, терминал, браузер): та же команда `open`, приложение выходит
/// вперёд. Страница уже на экране — остаётся в своей вкладке, иначе — новой вкладкой; окна нет или в нём лист — новое окно.
extension CommandExecutor {
    /// `nil` — страница показана; иначе — что не вышло, одной фразой для человека.
    public func openPageAddress(_ url: URL) async -> String? {
        guard let address = PageAddress(url: url) else { return "Эта ссылка не ведёт на страницу MyNotion." }
        let response = await run(openRequest(address))
        guard let error = response.error else { return nil }
        switch error.code {
        case .blockNotFound:
            // Блок удалили — страница всё равно нужна.
            return await openPageAddress(PageAddress(pageId: address.pageId).url)
        case .pageNotFound:
            return "Страница по ссылке не найдена: её удалили навсегда или она ещё не пришла с другого устройства."
        case .pageInTrash:
            let title = (try? host.store.page(address.pageId))?.title ?? ""
            return "Страница\(title.isEmpty ? "" : " «\(title)»") в корзине. Чтобы открыть её, верните страницу из корзины."
        default:
            return "Страницу открыть не удалось: \(error.message)"
        }
    }

    private func openRequest(_ address: PageAddress) -> ControlRequest {
        var args: [String: ControlJSON] = ["page": .string(address.pageId.controlText), "activate": true]
        if let blockId = address.blockId { args["block"] = .string(blockId.controlText) }
        let windows = host.windowControl.windows()
        if let front = windows.first(where: \.isFront) ?? windows.first {
            if front.isBusy {
                args["newWindow"] = true
            } else if front.tabs.first(where: \.isSelected)?.pageId != address.pageId {
                args["newTab"] = true
            }
        }
        return ControlRequest(command: "open", args: args, agent: "Ссылка")
    }
}
