import Foundation

/// Шаблон в строках пустой страницы: название и иконка.
public struct TemplateChoice: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let icon: String?

    public init(id: UUID, title: String, icon: String?) {
        self.id = id
        self.title = title
        self.icon = icon
    }
}

/// Что хозяин страницы даёт строкам шаблонов (US7): список шаблонов и что делать при выборе.
public struct TemplateSettings {
    public var templates: [TemplateChoice]
    public var choose: @MainActor (UUID) -> Void

    public init(templates: [TemplateChoice] = [], choose: @escaping @MainActor (UUID) -> Void = { _ in }) {
        self.templates = templates
        self.choose = choose
    }

    @MainActor
    func apply(to textView: PageTextView) {
        textView.onChooseTemplate = choose
        textView.templateChoices = templates
    }
}
