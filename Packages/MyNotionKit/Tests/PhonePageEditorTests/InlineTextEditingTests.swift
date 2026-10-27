import Foundation
import NotesCore
import Testing
@testable import PhonePageEditor

/// Разрез и склейка текста со стилями (Enter и ⌫ в начале блока), стили набора, место курсора после чужой правки.
struct InlineTextEditingTests {
    private let mentionId = UUID()

    @Test func splitKeepsStylesOnBothSides() {
        let text = InlineText("Привет мир", runs: [StyledRun(start: 0, length: 10, style: .bold),
                                                   StyledRun(start: 7, length: 3, style: .textColor(.red))])
        let (head, tail) = text.split(at: 6)
        #expect(head == InlineText("Привет", runs: [StyledRun(start: 0, length: 6, style: .bold)]))
        #expect(tail == InlineText(" мир", runs: [StyledRun(start: 0, length: 4, style: .bold),
                                                  StyledRun(start: 1, length: 3, style: .textColor(.red))]))
    }

    @Test func splitBeforeAtomMovesAtomWhole() {
        let text = InlineText("ab\u{FFFC}c", runs: [StyledRun(start: 2, length: 1, style: .mention(mentionId))])
        let (head, tail) = text.split(at: 2)
        #expect(head == InlineText("ab"))
        #expect(tail == InlineText("\u{FFFC}c", runs: [StyledRun(start: 0, length: 1, style: .mention(mentionId))]))
    }

    @Test func splitCountsUTF16() {
        let text = InlineText("😀ab", runs: [StyledRun(start: 2, length: 2, style: .italic)])
        let (head, tail) = text.split(at: 3)
        #expect(head == InlineText("😀a", runs: [StyledRun(start: 2, length: 1, style: .italic)]))
        #expect(tail == InlineText("b", runs: [StyledRun(start: 0, length: 1, style: .italic)]))
    }

    @Test func appendingShiftsRunsOfTail() {
        let url = URL(string: "https://kurilov.cloud")!
        let head = InlineText("ab", runs: [StyledRun(start: 0, length: 2, style: .italic)])
        let tail = InlineText("cd\u{FFFC}", runs: [StyledRun(start: 0, length: 2, style: .link(url)),
                                                   StyledRun(start: 2, length: 1, style: .equation("x^2"))])
        #expect(head.appending(tail) == InlineText("abcd\u{FFFC}", runs: [
            StyledRun(start: 0, length: 2, style: .italic),
            StyledRun(start: 2, length: 2, style: .link(url)),
            StyledRun(start: 4, length: 1, style: .equation("x^2")),
        ]))
    }

    @Test func typingContinuesFormattingButNotLinksOrAtoms() {
        let url = URL(string: "https://kurilov.cloud")!
        let text = InlineText("ab\u{FFFC}c", runs: [
            StyledRun(start: 0, length: 1, style: .bold),
            StyledRun(start: 0, length: 1, style: .backgroundColor(.yellow)),
            StyledRun(start: 1, length: 1, style: .link(url)),
            StyledRun(start: 1, length: 1, style: .code),
            StyledRun(start: 2, length: 1, style: .mention(mentionId)),
        ]).normalized()
        #expect(Set(text.typingStyles(at: 1)) == [.bold, .backgroundColor(.yellow)])
        #expect(text.typingStyles(at: 2) == [.code])
        #expect(text.typingStyles(at: 3).isEmpty)
        // В начале блока — как у первого знака.
        #expect(Set(text.typingStyles(at: 0)) == [.bold, .backgroundColor(.yellow)])
        #expect(InlineText().typingStyles(at: 0).isEmpty)
    }

    @Test func caretAfterChangedPartShifts() {
        let mapped = SelectionMapping.map(NSRange(location: 8, length: 0), from: "один два", to: "раз один два")
        #expect(mapped == NSRange(location: 12, length: 0))
    }

    @Test func caretBeforeChangedPartStays() {
        let mapped = SelectionMapping.map(NSRange(location: 2, length: 0), from: "один два", to: "один два три")
        #expect(mapped == NSRange(location: 2, length: 0))
    }

    @Test func caretInsideRemovedPartMovesToItsStart() {
        let mapped = SelectionMapping.map(NSRange(location: 6, length: 0), from: "один два три", to: "один три")
        #expect(mapped == NSRange(location: 5, length: 0))
    }

    @Test func selectionKeepsCoveringSameText() {
        let mapped = SelectionMapping.map(NSRange(location: 5, length: 3), from: "один два", to: "ноль один два")
        #expect(mapped == NSRange(location: 10, length: 3))
    }
}
