import Testing
@testable import AIModels

@Suite("Каталог моделей")
struct ModelCatalogTests {
    @Test("Три модели по порядку, без автовыбора; DeepSeek по умолчанию")
    func models() {
        #expect(ModelCatalog.all.map(\.title) == ["DeepSeek 4.1 Flash", "GLM 5.3 Flash", "Qwen 3.8 Flash"])
        #expect(ModelCatalog.defaultModel == ModelCatalog.deepSeekFlash)
        #expect(Set(ModelCatalog.all.map(\.id)).count == 3)
        for model in ModelCatalog.all { #expect(ModelCatalog.model(id: model.id) == model) }
        #expect(ModelCatalog.model(id: "auto") == nil)
    }

    @Test("DeepSeek: напрямую, запасной путь — OpenRouter Nitro")
    func deepSeekRoutes() {
        let routes = ModelCatalog.deepSeekFlash.routes
        #expect(routes.map(\.provider) == [.deepSeek, .openRouter])
        #expect(routes.map(\.modelID) == ["deepseek-flash", "deepseek/deepseek-v4.1-flash-1017:nitro"])
    }

    @Test("GLM и Qwen — только OpenRouter Nitro")
    func openRouterRoutes() {
        #expect(ModelCatalog.glmFlash.routes == [ModelRoute(provider: .openRouter, modelID: "z-ai/glm-5.3-flash:nitro", reasoning: .effort)])
        #expect(ModelCatalog.qwenFlash.routes == [ModelRoute(provider: .openRouter, modelID: "qwen/qwen3.8-flash:nitro", reasoning: .toggle)])
    }

    @Test("Уровни — ровно те, что умеет модель, с понятными подписями")
    func levels() {
        #expect(ModelCatalog.deepSeekFlash.options.map(\.level) == [.none, .low, .high, .max])
        #expect(ModelCatalog.deepSeekFlash.options.map(\.title) == ["Без рассуждений", "Коротко", "Подробно", "Максимум"])
        #expect(ModelCatalog.glmFlash.options.map(\.level) == [.low, .medium, .high])
        #expect(ModelCatalog.glmFlash.options.map(\.title) == ["Коротко", "Средне", "Подробно"])
        #expect(ModelCatalog.qwenFlash.options.map(\.level) == [.none, .high])
        #expect(ModelCatalog.qwenFlash.options.map(\.title) == ["Без рассуждений", "С рассуждениями"])
        for model in ModelCatalog.all { #expect(model.supports(model.defaultLevel)) }
    }

    @Test("Уровень, которого модель не умеет, заменяется её уровнем по умолчанию")
    func resolvedLevel() {
        #expect(ModelCatalog.glmFlash.resolvedLevel(.none) == ModelCatalog.glmFlash.defaultLevel)
        #expect(ModelCatalog.qwenFlash.resolvedLevel(.low) == ModelCatalog.qwenFlash.defaultLevel)
        #expect(ModelCatalog.deepSeekFlash.resolvedLevel(.max) == .max)
    }
}
