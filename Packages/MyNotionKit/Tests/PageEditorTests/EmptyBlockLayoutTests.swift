import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Пустой блок стоит там же, где стоял бы с текстом: курсор, подсказка и маркер — на одной строке
/// (contracts/visual-style.md, «Пустые строки»), в середине страницы и в конце.
@MainActor
@Suite("Пустые блоки: курсор, подсказка и маркер")
struct EmptyBlockLayoutTests {
    typealias Spec = EditorFixture.Spec

    static let emptyKinds: [Spec] = [.paragraph(), .heading(1, ""), .heading(2, ""), .heading(3, ""), .bullet(""), .numbered(""), .checkbox("")]
    static let surroundings: [(name: String, above: [Spec], below: [Spec])] = [
        ("один на странице", [], []),
        ("в конце после текста", [.paragraph("Выше")], []),
        ("в конце после пустого", [.checkbox("")], []),
        ("в конце после двух пустых", [.bullet(""), .paragraph()], []),
        ("в середине", [.paragraph("Выше")], [.paragraph("Ниже")]),
        ("в середине после пустого", [.bullet("")], [.paragraph("Ниже")]),
    ]

    /// Рамка курсора в координатах текстового контейнера.
    static func caretLine(in editor: EditorFixture) -> CGRect {
        let textView = editor.textView
        let onScreen = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        let rect = textView.convert(editor.window.convertFromScreen(onScreen), from: nil)
        return rect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
    }

    @Test("Курсор пустого блока стоит на строке этого блока с текстом, маркер и подсказка — на той же строке")
    func emptyBlockSitsOnItsLine() throws {
        for empty in Self.emptyKinds {
            for place in Self.surroundings {
                let label = "\(empty.kind) \(place.name)"
                let index = place.above.count
                var filledSpec = empty
                filledSpec.text = "Ж"
                let filled = try EditorFixture(place.above + [filledSpec] + place.below)
                filled.placeCaret(inBlock: index)
                let expected = Self.caretLine(in: filled)

                let editor = try EditorFixture(place.above + [empty] + place.below)
                editor.placeCaret(inBlock: index)
                let caret = Self.caretLine(in: editor)
                #expect(abs(caret.minY - expected.minY) < 0.5 && abs(caret.height - expected.height) < 0.5,
                        "Курсор \(label): \(caret.minY)…\(caret.maxY), с текстом \(expected.minY)…\(expected.maxY)")

                if empty.kind.hasMarkerColumn {
                    let marker = try #require(editor.textView.markerLine(ofBlockAt: index), "\(label)")
                    let filledMarker = try #require(filled.textView.markerLine(ofBlockAt: index), "\(label)")
                    #expect(abs(marker.top - caret.minY) < 0.5, "Маркер и курсор \(label): \(marker.top) и \(caret.minY)")
                    #expect(abs(marker.baseline - filledMarker.baseline) < 0.5, "Маркер \(label) там же, где с текстом")
                }

                let hint = editor.textView.emptyParagraphHint
                #expect(!hint.isHidden, "Подсказка видна: \(label)")
                let caretMidY = caret.midY + editor.textView.textContainerOrigin.y
                #expect(abs(hint.frame.midY - caretMidY) < 0.5, "Подсказка на строке курсора: \(label)")
            }
        }
    }

    @Test("Подсказка пустого блока зависит от его типа, как в Notion")
    func hintDependsOnKind() throws {
        let expected: [(Spec, String)] = [
            (.paragraph(), "Введите «/» для выбора блока"),
            (.bullet(""), "Список"),
            (.numbered(""), "Список"),
            (.checkbox(""), "Задача"),
            (.heading(1, ""), "Заголовок 1"),
            (.heading(2, ""), "Заголовок 2"),
            (.heading(3, ""), "Заголовок 3"),
        ]
        for (spec, text) in expected {
            let editor = try EditorFixture([.paragraph("Выше"), spec, .paragraph("Ниже")])
            editor.placeCaret(inBlock: 1)
            #expect(editor.textView.emptyParagraphHint.stringValue == text, "\(spec.kind)")
            #expect(editor.textView.emptyParagraphHint.textColor == Palette.textSecondary)
        }
    }

    // MARK: Последний перевод строки

    @Test("Курсор и выделение не заходят за перевод строки последнего блока")
    func selectionStopsBeforeFinalNewline() throws {
        let editor = try EditorFixture([.paragraph("Выше"), .bullet("")])
        let length = editor.textView.string.utf16.count
        editor.textView.setSelectedRange(NSRange(location: length, length: 0))
        #expect(editor.textView.selectedRange() == NSRange(location: length - 1, length: 0))
        editor.textView.selectAll(nil)
        #expect(editor.textView.selectedRange() == NSRange(location: 0, length: length - 1))
    }

    @Test("⌦ в конце последнего блока ничего не удаляет")
    func deleteForwardAtPageEndKeepsBlocks() throws {
        let editor = try EditorFixture([.paragraph("Выше"), .checkbox("")])
        editor.placeCaret(inBlock: 1)
        editor.press(#selector(NSResponder.deleteForward(_:)))
        #expect(editor.kinds == [.paragraph, .checkbox])
        #expect(editor.textView.string == "Выше\n\n")
    }

    @Test("Выделить всё и удалить — остаётся один пустой блок, набор идёт в него")
    func deletingEverythingLeavesOneBlock() throws {
        let editor = try EditorFixture([.paragraph("Один"), .bullet("два"), .checkbox("")])
        editor.textView.selectAll(nil)
        editor.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(editor.texts == [""])
        editor.type("новое")
        #expect(editor.texts == ["новое"])
        #expect(editor.textView.string == "новое\n")
    }
}
