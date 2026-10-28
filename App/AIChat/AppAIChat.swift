import Foundation
import Proofreading

/// ИИ-агент в приложении: ключ OpenRouter — в Связке ключей, своей записью; ключ DeepSeek — общий с «Исправить ошибки».
@MainActor
enum AppAIChat {
    static let openRouterKeychain = ProofreadingKeychain(service: "cloud.kurilov.mynotion.openrouter", label: "MyNotion — ключ OpenRouter")
}
