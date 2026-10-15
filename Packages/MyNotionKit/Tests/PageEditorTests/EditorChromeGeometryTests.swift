import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Геометрия редактора вокруг текста по проверке интерфейса 15.10.2026 (ui-review, зона US3):
/// ручки блока, иконка страницы, курсор у подсказки.
@MainActor
@Suite("Геометрия редактора по проверке интерфейса")
struct EditorChromeGeometryTests {
    typealias Spec = EditorFixture.Spec

    @Test("Ручки «+ ⋮⋮» по середине строчных букв первой строки блока, как маркер (№ 10)")
    func handlesCenterOnFirstLine() throws {
        let specs: [Spec] = [.paragraph("Абзац текста"), .heading(1, "Заголовок"), .heading(3, "Малый"), .bullet("Пункт"), .checkbox("Задача")]
        let editor = try EditorFixture(specs)
        let textView = editor.textView
        for (index, spec) in specs.enumerated() {
            let line = try #require(textView.markerLine(ofBlockAt: index))
            textView.blockHandles.show(forBlockAt: index, line: line)
            let font = Typography.line(for: PageTextStorageMapper.textStyle(of: spec.kind)).font
            let expected = textView.textContainerOrigin.y + line.baseline - font.xHeight / 2
            let handles = textView.blockHandles.frame
            #expect(abs(handles.midY - expected) < 0.5, "\(spec.kind): середина ручек \(handles.midY), середина строчных \(expected)")
        }
    }
}
