import AppKit
import VisualStyle
import Testing
@testable import NotesCore
@testable import PageEditor

/// Упоминание и дата рисуются в тексте: на месте знака есть «чернила» (contracts/blocks-and-keys.md).
@MainActor
@Suite("Вид упоминаний и дат")
struct InlineAtomLookTests {
    @Test("На месте упоминания и даты нарисованы название и дата, в обеих темах")
    func atomsAreDrawn() throws {
        let editor = try EditorFixture([.paragraph()])
        let target = UUID()
        editor.textView.mentionDirectory = MentionDirectory(pages: [target: LinkedPage(title: "Планы", icon: "📘")])
        editor.placeCaret(inBlock: 0)
        let date = DateMention(start: "2030-10-20", includesTime: false, timeZone: "Europe/Moscow")
        editor.step { editor.textView.insertAtom(.mention(target), in: NSRange(location: 0, length: 0), blockAt: 0) }
        editor.step { editor.textView.insertAtom(.date(date), in: NSRange(location: 1, length: 0), blockAt: 0) }
        editor.textView.layoutSubtreeIfNeeded()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for index in 0..<2 {
                let pixels = try ViewPixels(editor.textView, appearance: appearance)
                let screen = editor.textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
                let local = editor.textView.convert(editor.window.convertFromScreen(screen), from: nil)
                #expect(local.width > 20, "атом \(index) без ширины")
                let background = Palette.pageBackgroundResolved(appearance)
                #expect(pixels.inkBounds(in: local.insetBy(dx: 1, dy: 1), over: background) != nil, "атом \(index) не нарисован (\(appearance.rawValue))")
            }
        }
    }
}

private extension Palette {
    static func pageBackgroundResolved(_ appearance: NSAppearance.Name) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        Palette.pageBackground.resolved(in: appearance)
    }
}
