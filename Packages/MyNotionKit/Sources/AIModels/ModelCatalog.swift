import Foundation

/// Сила рассуждений. Какие уровни есть у модели — решает её `ChatModel.options`.
public enum ReasoningLevel: String, Sendable, Hashable, Codable, CaseIterable {
    case none, low, medium, high, max
}

/// Уровень в списке рядом с моделью.
public struct ReasoningOption: Sendable, Hashable {
    public let level: ReasoningLevel
    public let title: String
}

/// Куда уходит запрос.
public enum ModelProvider: String, Sendable, Hashable, Codable {
    case deepSeek, openRouter

    public var title: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .openRouter: "OpenRouter"
        }
    }

    var endpoint: URL {
        switch self {
        case .deepSeek: URL(string: "https://api.deepseek.com/chat/completions")!
        case .openRouter: URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        }
    }
}

/// Как модель на этом пути принимает силу рассуждений (проверено живыми запросами 2026-10-28).
public enum ReasoningControl: Sendable, Hashable {
    /// DeepSeek напрямую: `thinking` + `reasoning_effort`.
    case deepSeekThinking
    /// OpenRouter: `reasoning.effort`, «без рассуждений» — `reasoning.enabled = false`.
    case effort
    /// OpenRouter, модель силу не принимает: только `reasoning.enabled`.
    case toggle
}

/// Один путь к модели: поставщик и id модели у него.
public struct ModelRoute: Sendable, Hashable {
    public let provider: ModelProvider
    public let modelID: String
    public let reasoning: ReasoningControl

    public init(provider: ModelProvider, modelID: String, reasoning: ReasoningControl) {
        self.provider = provider
        self.modelID = modelID
        self.reasoning = reasoning
    }
}

/// Модель в списке чата. Первый путь — основной, следующие — запасные.
public struct ChatModel: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let options: [ReasoningOption]
    public let defaultLevel: ReasoningLevel
    public let routes: [ModelRoute]

    public func supports(_ level: ReasoningLevel) -> Bool {
        options.contains { $0.level == level }
    }

    /// Уровень, сохранённый для другой модели, может не подойти этой.
    public func resolvedLevel(_ level: ReasoningLevel) -> ReasoningLevel {
        supports(level) ? level : defaultLevel
    }

    public func title(for level: ReasoningLevel) -> String {
        options.first { $0.level == level }?.title ?? ""
    }
}

public enum ModelCatalog {
    public static let deepSeekFlash = ChatModel(
        id: "deepseek-flash", title: "DeepSeek 4.1 Flash",
        options: [.init(level: .none, title: "Без рассуждений"), .init(level: .low, title: "Коротко"),
                  .init(level: .high, title: "Подробно"), .init(level: .max, title: "Максимум")],
        defaultLevel: .high,
        routes: [ModelRoute(provider: .deepSeek, modelID: "deepseek-flash", reasoning: .deepSeekThinking),
                 ModelRoute(provider: .openRouter, modelID: "deepseek/deepseek-v4.1-flash-1017:nitro", reasoning: .effort)])

    /// Без рассуждений GLM не работает: OpenRouter отвечает «Reasoning is mandatory».
    public static let glmFlash = ChatModel(
        id: "glm-flash", title: "GLM 5.3 Flash",
        options: [.init(level: .low, title: "Коротко"), .init(level: .medium, title: "Средне"), .init(level: .high, title: "Подробно")],
        defaultLevel: .medium,
        routes: [ModelRoute(provider: .openRouter, modelID: "z-ai/glm-5.3-flash:nitro", reasoning: .effort)])

    /// Силу рассуждений Qwen не принимает: на любой уровень тратит столько же.
    public static let qwenFlash = ChatModel(
        id: "qwen-flash", title: "Qwen 3.8 Flash",
        options: [.init(level: .none, title: "Без рассуждений"), .init(level: .high, title: "С рассуждениями")],
        defaultLevel: .none,
        routes: [ModelRoute(provider: .openRouter, modelID: "qwen/qwen3.8-flash:nitro", reasoning: .toggle)])

    public static let all = [deepSeekFlash, glmFlash, qwenFlash]
    public static let defaultModel = deepSeekFlash

    public static func model(id: String) -> ChatModel? {
        all.first { $0.id == id }
    }
}
