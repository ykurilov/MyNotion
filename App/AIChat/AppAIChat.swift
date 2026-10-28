import AIAgent
import AIChatHistory
import AIChatPanel
import AIModels
import ControlProtocol
import Foundation
import Proofreading

/// ИИ-агент в приложении: ключ OpenRouter — в Связке ключей, своей записью; ключ DeepSeek — общий с «Исправить ошибки».
@MainActor
enum AppAIChat {
    static let openRouterKeychain = ProofreadingKeychain(service: "cloud.kurilov.mynotion.openrouter", label: "MyNotion — ключ OpenRouter")

    /// Один клиент на все окна: поставщик, который только что сбоил, пропускается во всех чатах.
    static let modelClient: FallbackModelClient = {
        let deepSeek = AppProofreading.keychain
        let openRouter = openRouterKeychain
        return FallbackModelClient(routes: ModelRouteClient(keys: { provider in
            switch provider {
            case .deepSeek: (try? await deepSeek.key()) ?? nil
            case .openRouter: (try? await openRouter.key()) ?? nil
            }
        }))
    }()

    static func makeController(for model: MainWindowModel) -> AIChatController {
        AIChatController(chats: AIChatStore(store: model.store), model: modelClient, runner: runCommand,
                         openPage: { [weak model] in
                             guard let model else { return nil }
                             return await openPage(model)
                         })
    }

    /// Инструменты агента — команды каталога 005 через тот же исполнитель, что у `mynotion`.
    private static let runCommand: NoteToolbox.Runner = { @MainActor request in
        guard let executor = ControlBootstrap.executor else {
            return .failure(request.id, ControlError(.appNotReady, "Команды приложения ещё не готовы. Попробуйте через секунду."))
        }
        return await executor.run(request)
    }

    /// Открытая страница окна: название, путь от корня, родитель и текст — как их видит `page read`.
    private static func openPage(_ model: MainWindowModel) async -> AIChatController.OpenPage? {
        guard let pageId = model.openPageId else { return nil }
        let title = model.liveTitleOfOpenPage ?? ""
        let id = pageId.uuidString.lowercased()
        let read = await ControlBootstrap.executor?.run(ControlRequest(command: "page.read", args: ["page": .string(id)], agent: NoteToolbox.agentName))
        return AIChatController.OpenPage(pageID: id, title: title, read: read?.data)
    }
}
