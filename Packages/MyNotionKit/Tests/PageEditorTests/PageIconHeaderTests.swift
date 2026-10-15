import AppKit
@testable import EmojiPicker
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Иконка в шапке страницы, как в Notion (FR-034; contracts/editor-interactions.md, «Иконка страницы»):
/// без иконки при наведении на шапку над названием «Добавить иконку» (ставит случайную); иконка под мышью
/// подсвечена, щелчок открывает окно выбора под ней; выбор сообщается хозяину редактора.
@MainActor
@Suite("Иконка в шапке страницы")
struct PageIconHeaderTests {
    @Test("Без иконки: «Добавить иконку» видна только при наведении на шапку, над названием")
    func addIconButtonOnHover() throws {
        let editor = try EditorFixture()
        let header = editor.textView.header
        #expect(header.addIconButton.isHidden)
        header.isHovered = true
        header.layoutSubtreeIfNeeded()
        #expect(!header.addIconButton.isHidden)
        #expect(header.addIconButton.title == "Добавить иконку")
        #expect(header.addIconButton.frame.maxY + Metrics.PageHeaderButton.titleSpacing == header.titleField.frame.minY)
        #expect(header.addIconButton.frame.height == Metrics.PageHeaderButton.height)
        header.isHovered = false
        #expect(header.addIconButton.isHidden)
    }

    @Test("«Добавить иконку» ставит случайную, как у Notion")
    func addIconSetsRandom() throws {
        let editor = try EditorFixture()
        var chosen: [String?] = []
        editor.textView.onSetIcon = { chosen.append($0) }
        editor.textView.header.isHovered = true
        editor.textView.header.addIconButton.press()
        #expect(chosen.count == 1)
        #expect(chosen.first.flatMap { $0 }.map(NotesTransaction.isSingleEmoji) == true)
    }

    @Test("С иконкой кнопки нет; иконка под мышью подсвечена")
    func iconHover() throws {
        let editor = try EditorFixture(icon: "📘")
        let header = editor.textView.header
        header.isHovered = true
        #expect(header.addIconButton.isHidden)
        #expect(!header.iconView.isHidden)
        #expect(header.iconView.emoji == "📘")
        #expect(!header.iconView.isHovered)
        header.iconView.isHovered = true
        #expect(header.iconView.isHovered)
    }

    @Test("Щелчок по иконке открывает окно выбора под ней; выбор сообщается хозяину, окно закрывается")
    func iconClickOpensPicker() throws {
        let editor = try EditorFixture(icon: "📘")
        var chosen: [String?] = []
        editor.textView.onSetIcon = { chosen.append($0) }
        editor.textView.header.iconView.press()
        let picker = editor.textView.iconPicker
        #expect(picker.isShown)
        let icon = editor.textView.header.iconView
        let iconOnScreen = editor.window.convertToScreen(icon.convert(icon.bounds, to: nil))
        let card = try #require(picker.cardFrame)
        #expect(card.maxY == iconOnScreen.minY - Metrics.EmojiPicker.anchorSpacing)
        #expect(abs(card.midX - iconOnScreen.midX) <= 1)
        picker.view?.query = "лист"
        _ = picker.view?.handleCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(chosen.count == 1)
        #expect(!picker.isShown)
    }

    @Test("Страницу закрыли — окно выбора не остаётся висеть")
    func closingPageClosesPicker() throws {
        let editor = try EditorFixture(icon: "📘")
        editor.textView.openIconPicker()
        #expect(editor.textView.iconPicker.isShown)
        editor.textView.enclosingScrollView?.removeFromSuperview()
        #expect(!editor.textView.iconPicker.isShown)
    }

    @Test("Хозяин поставил и убрал иконку — шапка и текст страницы сдвигаются, как при открытии такой страницы")
    func showIconRelayouts() throws {
        let editor = try EditorFixture()
        let view = editor.textView
        view.header.layoutSubtreeIfNeeded()
        let titleWithout = view.header.titleField.frame.minY
        let bodyWithout = view.textContainerOrigin.y
        view.showIcon("📘")
        view.header.layoutSubtreeIfNeeded()
        #expect(!view.header.iconView.isHidden)
        #expect(view.header.iconView.emoji == "📘")
        let withIcon = try EditorFixture(icon: "📘")
        withIcon.textView.header.layoutSubtreeIfNeeded()
        #expect(withIcon.textView.header.titleField.frame.minY > titleWithout)
        #expect(view.header.titleField.frame.minY == withIcon.textView.header.titleField.frame.minY)
        #expect(view.textContainerOrigin.y == withIcon.textView.textContainerOrigin.y)
        #expect(view.textContainerOrigin.y > bodyWithout)
        view.showIcon(nil)
        view.header.layoutSubtreeIfNeeded()
        #expect(view.header.iconView.isHidden)
        #expect(view.header.titleField.frame.minY == titleWithout)
        #expect(view.textContainerOrigin.y == bodyWithout)
    }
}
