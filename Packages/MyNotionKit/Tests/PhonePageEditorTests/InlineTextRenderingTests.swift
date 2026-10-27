#if canImport(UIKit)
import Foundation
import NotesCore
import Testing
import UIKit
@testable import PhonePageEditor

/// Текст с оформлением Mac в поле iPhone и обратно: ничего не теряется, набор не портит соседей.
@MainActor
struct InlineTextRenderingTests {
    private let mentionId = UUID()
    private let date = DateMention(start: "2026-10-20", includesTime: false, timeZone: "Europe/Moscow")

    private var rendering: InlineTextRendering {
        InlineTextRendering(look: .paragraph, traits: UITraitCollection(userInterfaceStyle: .light)) { _ in "Планы" }
    }

    /// Все виды оформления сразу, с пересечениями и атомами.
    private var richText: InlineText {
        InlineText("жирный курсив ссылка код \u{FFFC} \u{FFFC} \u{FFFC} цвет", runs: [
            StyledRun(start: 0, length: 13, style: .bold),
            StyledRun(start: 7, length: 6, style: .italic),
            StyledRun(start: 7, length: 13, style: .underline),
            StyledRun(start: 14, length: 6, style: .link(URL(string: "https://kurilov.cloud")!)),
            StyledRun(start: 21, length: 3, style: .code),
            StyledRun(start: 21, length: 3, style: .strikethrough),
            StyledRun(start: 25, length: 1, style: .mention(mentionId)),
            StyledRun(start: 27, length: 1, style: .date(date)),
            StyledRun(start: 29, length: 1, style: .equation("x^2")),
            StyledRun(start: 31, length: 4, style: .textColor(.red)),
            StyledRun(start: 31, length: 4, style: .backgroundColor(.yellow)),
        ]).normalized()
    }

    @Test func roundTripKeepsEveryStyle() {
        let shown = rendering.attributedString(richText)
        #expect(InlineTextRendering.inlineText(from: shown) == richText)
        #expect(shown.attribute(.attachment, at: 25, effectiveRange: nil) is NSTextAttachment)
    }

    @Test func atomsAreLabelledLikeOnMac() {
        #expect(rendering.atomLabel(.mention(mentionId)) == "↗ Планы")
        #expect(rendering.atomLabel(.equation("x^2")) == "x^2")
        #expect(rendering.atomLabel(.date(date)).hasPrefix("@"))
    }

    @Test func typingInsideStyledTextKeepsNeighbours() {
        let textView = BlockTextView()
        textView.attributedText = rendering.attributedString(richText)
        textView.selectedRange = NSRange(location: 3, length: 0)
        textView.typingAttributes = rendering.typingAttributes(in: richText, at: 3)
        textView.insertText("ЖЖ")

        let edited = InlineTextRendering.inlineText(from: textView.attributedText)
        var expected = richText
        expected.string = "жирЖЖный курсив ссылка код \u{FFFC} \u{FFFC} \u{FFFC} цвет"
        expected.runs = richText.runs.map { run in
            var run = run
            if run.start >= 3 { run.start += 2 } else if run.start + run.length > 3 { run.length += 2 }
            return run
        }
        #expect(edited == expected.normalized())
    }

    @Test func typingAfterLinkOrAtomIsPlain() {
        let textView = BlockTextView()
        textView.attributedText = rendering.attributedString(richText)
        textView.selectedRange = NSRange(location: 26, length: 0)
        textView.typingAttributes = rendering.typingAttributes(in: richText, at: 26)
        textView.insertText("!")

        let edited = InlineTextRendering.inlineText(from: textView.attributedText)
        #expect(!edited.runs.contains { $0.start <= 26 && $0.start + $0.length > 26 })
        #expect(edited.runs.filter(\.style.isAtom).count == 3)
    }

    @Test func deletingTextKeepsOtherStyles() {
        let textView = BlockTextView()
        textView.attributedText = rendering.attributedString(richText)
        textView.selectedRange = NSRange(location: 14, length: 7)
        textView.deleteBackward()

        let edited = InlineTextRendering.inlineText(from: textView.attributedText)
        #expect(edited.string == "жирный курсив код \u{FFFC} \u{FFFC} \u{FFFC} цвет")
        #expect(!edited.runs.contains { if case .link = $0.style { true } else { false } })
        #expect(edited.runs.contains(StyledRun(start: 14, length: 3, style: .code)))
        #expect(edited.runs.contains(StyledRun(start: 18, length: 1, style: .mention(mentionId))))
        #expect(edited.runs.contains(StyledRun(start: 24, length: 4, style: .textColor(.red))))
    }
}

/// Экран целиком в окне: набор уходит в документ, правка с другого устройства не сбивает курсор.
@MainActor
struct PhonePageScreenTests {
    private func screen(_ page: PhonePageFixture) throws -> (PhonePageViewController, UIWindow) {
        let screen = try PhonePageViewController(pageId: page.pageId, openDocuments: page.openDocuments) { _ in }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return (screen, window)
    }

    private func textView(of blockId: UUID, in view: UIView) -> BlockTextView? {
        if let textView = view as? BlockTextView, textView.blockId == blockId { return textView }
        return view.subviews.lazy.compactMap { textView(of: blockId, in: $0) }.first
    }

    @Test func externalEditBeforeCaretShiftsCaretInFocusedBlock() throws {
        let page = try PhonePageFixture([.paragraph("пишу здесь"), .paragraph("ниже")])
        let (screen, window) = try screen(page)
        let field = try #require(textView(of: page.ids[0], in: window))
        field.becomeFirstResponder()
        field.selectedRange = NSRange(location: 5, length: 0)

        try page.editElsewhere(page.ids[0]) { $0.text = InlineText("Mac: пишу здесь") }

        #expect(field.text == "Mac: пишу здесь")
        #expect(field.selectedRange == NSRange(location: 10, length: 0))
        #expect(field.isFirstResponder)
        _ = screen
    }

    @Test func typingGoesToDocumentAndSurvivesExternalEditOfOtherBlock() throws {
        let page = try PhonePageFixture([.paragraph("пишу", runs: [StyledRun(start: 0, length: 4, style: .bold)]), .paragraph("ниже")])
        let (screen, window) = try screen(page)
        let field = try #require(textView(of: page.ids[0], in: window))
        field.becomeFirstResponder()
        field.selectedRange = NSRange(location: 4, length: 0)
        field.insertText("!")

        try page.editElsewhere(page.ids[1]) { $0.text = InlineText("ниже с Mac") }

        #expect(page.texts == ["пишу!", "ниже с Mac"])
        #expect(page.document.blocks[0].text.runs == [StyledRun(start: 0, length: 5, style: .bold)])
        #expect(field.text == "пишу!")
        #expect(field.selectedRange == NSRange(location: 5, length: 0))
        _ = screen
    }

    @Test func thousandBlocksOpenTypeAndSplitWithoutLag() throws {
        let page = try PhonePageFixture((0..<1000).map { .paragraph("Строка \($0): обычный текст абзаца") })
        let start = ContinuousClock.now
        let (screen, window) = try screen(page)
        let field = try #require(textView(of: page.ids[0], in: window))
        field.becomeFirstResponder()
        field.selectedRange = NSRange(location: 6, length: 0)
        for _ in 0..<30 { field.insertText("ы") }
        field.insertText("\n")
        let elapsed = ContinuousClock.now - start

        #expect(page.document.blocks.count == 1001)
        #expect(page.texts[1].hasPrefix(" 0:"))
        #expect(elapsed < .seconds(2), "открытие, 30 знаков и Enter заняли \(elapsed)")
        _ = screen
    }
}
#endif
