import AppKit
import Testing
import VisualStyle
@testable import PageTree

/// Вопрос перед удалением навсегда (№ 8, 24): затемнение только над содержимым окна и над окном корзины,
/// красная кнопка с белым текстом в обеих темах.
@MainActor
@Suite("Вопрос перед удалением навсегда")
struct TrashConfirmationTests {
    @Test("Затемнение — над содержимым окна, заголовок со светофором открыт")
    func overlayLeavesTitleBarOpen() {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        let overlay = ConfirmationDialogWindow.overlayFrame(over: parent)
        #expect(overlay.minX == parent.frame.minX)
        #expect(overlay.width == parent.frame.width)
        #expect(overlay.minY == parent.frame.minY)
        #expect(overlay.maxY <= parent.frame.maxY - 20, "затемнение закрывает заголовок окна")
        #expect(overlay.maxY > parent.frame.maxY - 60)
    }

    @Test("Вопрос — над окном корзины: корзина затемнена вместе со страницей")
    func dialogAboveTrashPanel() {
        let dialog = ConfirmationDialogWindow(title: "Удалить?", message: "", action: "Удалить навсегда")
        let panel = TrashPanelWindow(content: NSView())
        #expect(dialog.level.rawValue > panel.level.rawValue)
    }

    @Test("Вне карточки — затемнение, карточка непрозрачная, по центру", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func backdropAndCard(_ theme: NSAppearance.Name) throws {
        let view = dialogView(theme)
        let bitmap = try SidebarGeometryTests.render(view)
        #expect(bitmap.alpha(atX: 4, y: 4, flipped: true) > 0.35, "нет затемнения")
        let card = view.cardRect
        #expect(abs(card.midX - view.bounds.midX) < 1)
        #expect(bitmap.alpha(atX: card.midX, y: card.minY + 6, flipped: true) > 0.99, "карточка просвечивает")
    }

    @Test("«Удалить навсегда» — насыщенный красный с белым текстом", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func destructiveButtonReadable(_ theme: NSAppearance.Name) throws {
        let view = dialogView(theme)
        let bitmap = try SidebarGeometryTests.render(view)
        let button = view.convert(view.destructiveButton.bounds, from: view.destructiveButton)
        let fill = try #require(bitmap.color(atX: button.minX + 6, y: button.midY, flipped: true).usingColorSpace(.deviceRGB))
        #expect(fill.redComponent - fill.greenComponent > 0.35, "кнопка не красная: \(fill)")
        #expect(view.destructiveButton.titleColor == .white)
        #expect(Self.contrast(fill, .white) >= 4, "белый текст плохо читается: \(fill)")
    }

    @Test("«Отмена» по Enter и Esc, стирающая кнопка первой, как в Notion")
    func buttons() {
        let view = dialogView(.aqua)
        #expect(view.destructiveButton.title == "Удалить навсегда")
        #expect(view.cancelButton.title == "Отмена")
        #expect(view.cancelButton.keyEquivalent == "\r")
        #expect(view.destructiveButton.frame.minY < view.cancelButton.frame.minY)
    }

    @Test("Ответ доходит один раз: Отмена — нет, красная кнопка — да")
    func answers() {
        var answers: [Bool] = []
        let window = ConfirmationDialogWindow(title: "Удалить?", message: "", action: "Удалить навсегда")
        window.onAnswer = { answers.append($0) }
        window.dialog.destructiveButton.performClick(nil)
        window.cancelOperation(nil)
        #expect(answers == [true])
        let other = ConfirmationDialogWindow(title: "Удалить?", message: "", action: "Удалить навсегда")
        other.onAnswer = { answers.append($0) }
        other.cancelOperation(nil)
        #expect(answers == [true, false])
    }

    private func dialogView(_ theme: NSAppearance.Name) -> ConfirmationDialogView {
        let view = ConfirmationDialogView(title: "Удалить «Старые заметки» навсегда?",
                                          message: "Страница и её подстраницы сотрутся. Вернуть их будет нельзя.",
                                          action: "Удалить навсегда")
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.appearance = NSAppearance(named: theme)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Контраст по WCAG.
    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func luminance(_ c: NSColor) -> CGFloat {
            let c = c.usingColorSpace(.sRGB) ?? c
            func channel(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
        }
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
