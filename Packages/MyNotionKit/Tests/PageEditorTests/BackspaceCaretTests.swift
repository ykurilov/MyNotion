import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// После ⌫ курсор и подсказка пустого блока стоят на строке своего блока, а не на строке блока выше
/// (баг Юрия 25.10.2026: стёр текст пункта под заголовком — курсор и «Список» легли поверх заголовка, маркер остался внизу).
@MainActor
@Suite("⌫: курсор и подсказка на своей строке")
struct BackspaceCaretTests {
    typealias Spec = EditorFixture.Spec

    /// Страница из бага: заголовок, список, заголовок и пункт под ним.
    nonisolated static func page(lastItem: String, below: [Spec] = []) -> [Spec] {
        [.heading(2, "Нейропродавец"), .paragraph("За 5 недель создайте нейропродавца"),
         .heading(3, "Чему вы научитесь:"),
         .bullet("Запускать своего нейропродавца"), .bullet("Объяснять нейропродавцу"), .bullet("Находить клиентов"),
         .bullet("Настраивать нейропродавца"), .bullet("Делать нейропродавцов на заказ"),
         .heading(3, "Что вы сделаете:"), .bullet(lastItem)] + below
    }

    struct Scenario: CustomTestStringConvertible, Sendable {
        var name: String
        var specs: [Spec]
        var caretBlock: Int
        /// `nil` — курсор в конец текста блока.
        var caretOffset: Int?
        var presses: Int
        var testDescription: String { name }
    }

    nonisolated static let scenarios: [Scenario] = [
        Scenario(name: "пустой последний пункт под заголовком", specs: page(lastItem: ""), caretBlock: 9, caretOffset: 0, presses: 2),
        Scenario(name: "стирание последнего пункта", specs: page(lastItem: "абв"), caretBlock: 9, caretOffset: nil, presses: 5),
        Scenario(name: "стирание пункта под заголовком в середине", specs: page(lastItem: "абв", below: [.paragraph("Ниже")]),
                 caretBlock: 9, caretOffset: nil, presses: 5),
        Scenario(name: "начало непустого последнего пункта", specs: page(lastItem: "абв"), caretBlock: 9, caretOffset: 0, presses: 2),
        Scenario(name: "стирание пункта в середине списка", specs: page(lastItem: ""), caretBlock: 5, caretOffset: nil, presses: 22),
    ]

    @Test("После каждого ⌫ курсор, подсказка и строка блока с курсором — там же, где после раскладки всей страницы заново",
          arguments: scenarios)
    func caretFollowsLayout(_ scenario: Scenario) throws {
        let editor = try EditorFixture(scenario.specs)
        let textView = editor.textView
        textView.caret.showsWithoutKeyWindow = true
        editor.placeCaret(inBlock: scenario.caretBlock, at: scenario.caretOffset)
        for press in 1...scenario.presses {
            editor.press(#selector(NSResponder.deleteBackward(_:)))
            let label = "\(scenario.name), ⌫ №\(press)"
            let caret = textView.caret.isShown ? textView.caret.frame : nil
            let hint = textView.emptyParagraphHint.isHidden ? nil : textView.emptyParagraphHint.frame
            let caretBlock = try #require(textView.mapper.blockPosition(at: textView.selectedRange().location)).index
            let line = textView.markerLine(ofBlockAt: caretBlock)?.baseline

            let manager = try #require(textView.textLayoutManager)
            manager.ensureLayout(for: manager.documentRange)
            let settledLine = textView.markerLine(ofBlockAt: caretBlock)?.baseline
            #expect(line == settledLine, "\(label): строка блока \(caretBlock) — \(String(describing: line)), после раскладки \(String(describing: settledLine))")
            let settledCaret = TextCaret.rect(in: textView)
            #expect(caret == settledCaret, "\(label): курсор \(String(describing: caret)), после раскладки \(String(describing: settledCaret))")
            textView.updateEmptyParagraphHint()
            let settledHint = textView.emptyParagraphHint.isHidden ? nil : textView.emptyParagraphHint.frame
            #expect(hint == settledHint, "\(label): подсказка \(String(describing: hint)), после раскладки \(String(describing: settledHint))")
        }
    }
}
