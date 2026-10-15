import AppKit
import Testing
@testable import PageEditor

/// Название страницы и ручки «+ ⋮⋮» лежат внутри текста страницы. Доступность текстового поля своих вложенных
/// полей не показывает: без этого их не видят ни VoiceOver, ни UI-сценарии (`page-title`, `block-handle-*`).
@MainActor
@Suite("Доступность: название и ручки внутри текста страницы")
struct PageAccessibilityTests {
    /// Идентификаторы всех элементов доступности под `element`.
    func identifiers(under element: Any) -> Set<String> {
        guard let element = element as? NSAccessibilityProtocol else { return [] }
        var found: Set<String> = []
        for child in element.accessibilityChildren() ?? [] {
            if let id = (child as? NSAccessibilityProtocol)?.accessibilityIdentifier(), !id.isEmpty { found.insert(id) }
            found.formUnion(identifiers(under: child))
        }
        return found
    }

    @Test("Поле названия — среди элементов текста страницы")
    func titleFieldIsAccessible() throws {
        let editor = try EditorFixture([.paragraph("Текст")])
        #expect(identifiers(under: editor.textView).contains("page-title"))
    }

    @Test("Ручки «+ ⋮⋮» видны доступности, только пока показаны")
    func handlesAreAccessibleWhileShown() throws {
        let editor = try EditorFixture([.paragraph("Текст")])
        let textView = editor.textView
        textView.blockHandles.show(forBlockAt: 0, line: try #require(textView.markerLine(ofBlockAt: 0)))
        #expect(identifiers(under: textView).isSuperset(of: ["block-handle-add", "block-handle-drag"]))
        textView.blockHandles.hide()
        #expect(identifiers(under: textView).isDisjoint(with: ["block-handle-add", "block-handle-drag"]))
    }

    @Test("Текст страницы для доступности — блоки через перевод строки, без служебного перевода строки в конце")
    func bodyValueIsBlockText() throws {
        let editor = try EditorFixture([.paragraph("Молоко"), .paragraph("Хлеб")])
        #expect(editor.textView.accessibilityValue() as? String == "Молоко\nХлеб")
        #expect(try EditorFixture([.paragraph()]).textView.accessibilityValue() as? String == "")
    }
}
