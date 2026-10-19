import AppKit
import NotesCore
import PageEditor
import XCTest

/// Проба длинного кода (T004, research R5, SC-103): один абзац на 500 строк Swift, строки — переносы U+2028,
/// как будет у блока кода. На каждую правку — раскраска заглушкой через `setRenderingAttributes` (в текст,
/// отмену и документ не попадает). Набор в середине — p95 ≤ 50 мс.
@MainActor
final class LongCodeTypingProbeTests: XCTestCase {
    static let lineCount = 500
    static let keywords: Set<String> = ["func", "let", "var", "return", "if", "else", "for", "in", "struct", "import", "guard", "self"]

    static func swiftSource() -> String {
        (0..<lineCount).map { index in
            switch index % 5 {
            case 0: "func step\(index)(value: Int) -> Int {"
            case 1: "    let doubled = value * 2 // строка \(index)"
            case 2: "    guard doubled > 0 else { return 0 }"
            case 3: "    return doubled + \"текст\".count"
            default: "}"
            }
        }.joined(separator: "\u{2028}")
    }

    private func makeEditor() throws -> ProbeEditor {
        var specs: [ProbeEditor.Spec] = (0..<20).map { .init(text: "Абзац \($0) перед кодом") }
        specs.append(.init(text: Self.swiftSource()))
        specs += (0..<20).map { .init(text: "Абзац \($0) после кода") }
        return try ProbeEditor(specs)
    }

    /// Заглушка подсветки: ключевые слова строки с курсором (или всего блока) — цветом «атрибутами показа».
    private func colorKeywords(_ editor: ProbeEditor, wholeBlock: Bool) {
        let textView = editor.textView
        guard let layoutManager = textView.textLayoutManager, let storage = textView.textContentStorage else { return }
        let string = textView.string as NSString
        let caret = textView.selectedRange().location
        let paragraph = string.paragraphRange(for: NSRange(location: caret, length: 0))
        var range = paragraph
        if !wholeBlock {
            let separator = "\u{2028}"
            let before = string.range(of: separator, options: .backwards, range: NSRange(location: paragraph.location, length: caret - paragraph.location))
            let after = string.range(of: separator, range: NSRange(location: caret, length: NSMaxRange(paragraph) - caret))
            let start = before.location == NSNotFound ? paragraph.location : NSMaxRange(before)
            let end = after.location == NSNotFound ? NSMaxRange(paragraph) : after.location
            range = NSRange(location: start, length: end - start)
        }
        guard let from = storage.location(storage.documentRange.location, offsetBy: range.location),
              let to = storage.location(from, offsetBy: range.length),
              let textRange = NSTextRange(location: from, end: to) else { return }
        layoutManager.removeRenderingAttribute(.foregroundColor, for: textRange)
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            let word = string.rangeOfCharacter(from: .letters, options: [], range: NSRange(location: location, length: end - location))
            guard word.location != NSNotFound else { break }
            var wordEnd = word.location
            while wordEnd < end, let scalar = Unicode.Scalar(string.character(at: wordEnd)), CharacterSet.letters.contains(scalar) { wordEnd += 1 }
            let wordRange = NSRange(location: word.location, length: wordEnd - word.location)
            if Self.keywords.contains(string.substring(with: wordRange)),
               let a = storage.location(storage.documentRange.location, offsetBy: wordRange.location),
               let b = storage.location(a, offsetBy: wordRange.length), let r = NSTextRange(location: a, end: b) {
                layoutManager.addRenderingAttribute(.foregroundColor, value: NSColor.systemPink, for: r)
            }
            location = max(wordEnd, word.location + 1)
        }
    }

    func testTypingInMiddleOfLongCodeWithinBudget() async throws {
        let editor = try makeEditor()
        defer { editor.close() }
        try await editor.settle()
        let codeStart = editor.location(ofBlock: 20)
        let source = Self.swiftSource() as NSString
        let middleLine = source.range(of: "строка 251")
        editor.placeCaret(codeStart + NSMaxRange(middleLine))
        colorKeywords(editor, wholeBlock: true)

        let lineSamples = try await editor.type(100) { colorKeywords(editor, wholeBlock: false) }
        let blockSamples = try await editor.type(100) { colorKeywords(editor, wholeBlock: true) }
        let summary = """
            Набор в коде на 500 строк (одна строка перекрашивается): p95 \(ProbeEditor.format(ProbeEditor.p95(lineSamples))) мс, \
            худший \(ProbeEditor.format(lineSamples.max() ?? 0)) мс
            Набор в коде на 500 строк (весь блок перекрашивается): p95 \(ProbeEditor.format(ProbeEditor.p95(blockSamples))) мс, \
            худший \(ProbeEditor.format(blockSamples.max() ?? 0)) мс
            """
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertEqual(editor.document.blocks.count, 41)
        XCTAssertEqual((editor.document.blocks[20].text.string as NSString).length, source.length + 200)
        XCTAssertLessThanOrEqual(ProbeEditor.p95(lineSamples), 50, "Набор в коде на 500 строк: p95 больше 50 мс")
    }
}
