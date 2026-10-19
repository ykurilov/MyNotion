import AppKit
import NotesCore
import PageEditor
import XCTest

/// Набор в блоке кода на 500 строк (SC-103, T081): блок — встроенный редактор, строка кода — свой абзац
/// (research R5, «Решение 19.10.2026»). Как проба T004 (`LongCodeTypingProbeTests`), но в настоящем редакторе кода
/// с подсветкой Swift. Набор в середине — p95 ≤ 50 мс. Ещё: Enter меняет высоту блока, а курсор и редактор остаются.
@MainActor
final class CodeBlockTypingTests: XCTestCase {
    private func makeEditor() throws -> ProbeEditor {
        var specs: [ProbeEditor.Spec] = (0..<20).map { .init(text: "Абзац \($0) перед кодом") }
        specs.append(.init(kind: .code, text: LongCodeTypingProbeTests.swiftSource().replacingOccurrences(of: "\u{2028}", with: "\n"),
                           props: BlockProps(["language": .string("swift")])))
        specs += (0..<20).map { .init(text: "Абзац \($0) после кода") }
        return try ProbeEditor(specs)
    }

    /// Редакторы кода на странице: виды, которые TextKit создал для видимых строк.
    private static func codeEditors(in view: NSView) -> [NSTextView] {
        view.subviews.flatMap { subview -> [NSTextView] in
            if let textView = subview as? NSTextView, textView.accessibilityIdentifier() == "code-editor" { return [textView] }
            return codeEditors(in: subview)
        }
    }

    func testTypingInMiddleOfCodeBlockWithinBudget() async throws {
        let probe = try makeEditor()
        defer { probe.close() }
        let textView = probe.textView
        try await probe.settle()
        let codeLocation = probe.location(ofBlock: 20)
        textView.scrollRangeToVisible(NSRange(location: codeLocation, length: 1))
        probe.window.displayIfNeeded()
        try await probe.settle()

        let editors = Self.codeEditors(in: textView)
        XCTAssertEqual(editors.count, 1, "вид блока кода создан для видимой строки")
        let editor = try XCTUnwrap(editors.first)
        probe.window.makeFirstResponder(editor)
        let middle = (editor.string as NSString).range(of: "строка 251")
        editor.setSelectedRange(NSRange(location: NSMaxRange(middle), length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        probe.window.displayIfNeeded()

        var samples: [Double] = []
        let characters = Array("быстрый набор text ")
        for index in 0..<200 {
            let character = String(characters[index % characters.count])
            samples.append(ProbeEditor.measure {
                editor.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
                probe.window.displayIfNeeded()
            })
            try await Task.sleep(for: .milliseconds(10))
        }

        // Enter меняет высоту блока: редактор и курсор остаются.
        let caretBefore = editor.selectedRange().location
        let heightBefore = editor.enclosingScrollView?.superview?.frame.height ?? 0
        var enterSamples: [Double] = []
        for _ in 0..<5 {
            enterSamples.append(ProbeEditor.measure {
                editor.insertNewline(nil)
                probe.window.displayIfNeeded()
            })
            try await Task.sleep(for: .milliseconds(30))
        }
        try await probe.settle()
        let editorsAfter = Self.codeEditors(in: textView)
        let summary = """
            Набор в блоке кода на 500 строк (встроенный редактор, подсветка Swift): p95 \(ProbeEditor.format(ProbeEditor.p95(samples))) мс, \
            худший \(ProbeEditor.format(samples.max() ?? 0)) мс
            Проба Enter в блоке кода (высота растёт): худший \(ProbeEditor.format(enterSamples.max() ?? 0)) мс, \
            редакторов кода после: \(editorsAfter.count), фокус в редакторе: \(probe.window.firstResponder === editor), \
            высота вида \(Int(heightBefore)) → \(Int(editor.enclosingScrollView?.superview?.frame.height ?? 0))
            """
        print(summary)
        add(XCTAttachment(string: summary))
        let code = try XCTUnwrap(probe.document.blocks.first { $0.kind == .code })
        XCTAssertEqual(code.text.string, editor.string, "код в документе — как в редакторе")
        XCTAssertTrue(code.text.string.contains("строка 251быстрый набор text "))
        XCTAssertEqual(editorsAfter.count, 1)
        XCTAssertTrue(editorsAfter.first === editor, "Enter не пересоздал редактор")
        XCTAssertTrue(probe.window.firstResponder === editor, "курсор остался в коде")
        XCTAssertEqual(editor.selectedRange().location, caretBefore + 5 * 5, "курсор после пяти Enter с отступом в 4 пробела")
        XCTAssertLessThanOrEqual(ProbeEditor.p95(samples), 50, "Набор в блоке кода на 500 строк: p95 больше 50 мс")
    }
}
