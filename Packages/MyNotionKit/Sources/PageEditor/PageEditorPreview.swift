import AppKit
import NotesCore

/// Состояния редактора без мыши и клавиатуры: для галереи интерфейса (флаг `--ui-gallery`).
/// Каждое действие идёт тем же путём, что и у пользователя: показ ручек, набор «/», щелчок по «⋮⋮».
@MainActor
public enum PageEditorPreview {
    /// Текст открытой страницы в окне.
    public static func textView(in window: NSWindow) -> PageTextView? {
        window.contentView.flatMap(findTextView)
    }

    /// Ручки «+ ⋮⋮» у блока — как под мышью; `false` — блока нет на странице.
    @discardableResult
    public static func hoverBlock(_ blockId: UUID, in window: NSWindow) -> Bool {
        guard let textView = textView(in: window), let index = textView.document.index(ofBlock: blockId),
              let line = textView.markerLine(ofBlockAt: index) else { return false }
        textView.blockHandles.show(forBlockAt: index, line: line)
        return true
    }

    /// Курсор в конец текста блока.
    @discardableResult
    public static func placeCaret(atEndOf blockId: UUID, in window: NSWindow) -> Bool {
        guard let textView = textView(in: window), let index = textView.document.index(ofBlock: blockId) else { return false }
        let length = (textView.document.blocks[index].text.string as NSString).length
        textView.focusBody(at: textView.mapper.paragraphStart(ofBlockAt: index) + length)
        return true
    }

    /// Выделить `range` в тексте блока.
    @discardableResult
    public static func select(_ range: NSRange, inBlock blockId: UUID, in window: NSWindow) -> Bool {
        guard let textView = textView(in: window), let index = textView.document.index(ofBlock: blockId) else { return false }
        window.makeFirstResponder(textView)
        let start = textView.mapper.paragraphStart(ofBlockAt: index)
        textView.setSelectedRange(NSRange(location: start + range.location, length: range.length))
        return true
    }

    /// Набрать текст у курсора, как с клавиатуры: «/» открывает меню, дальше — фильтр.
    public static func type(_ text: String, in window: NSWindow) {
        guard let textView = textView(in: window) else { return }
        for character in text {
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    /// Меню блока, как по щелчку на «⋮⋮» его ручек.
    @discardableResult
    public static func openBlockMenu(forBlock blockId: UUID, in window: NSWindow) -> Bool {
        guard hoverBlock(blockId, in: window), let textView = textView(in: window) else { return false }
        let handles = textView.blockHandles
        guard let dragHandle = handles.subviews.compactMap({ $0 as? BlockHandleButton }).first(where: { $0.kind == .drag }) else {
            return false
        }
        let handleOnScreen = window.convertToScreen(dragHandle.convert(dragHandle.bounds, to: nil))
        textView.openBlockMenu(forBlock: blockId, below: handleOnScreen)
        return true
    }

    /// Прокрутить страницу до конца.
    public static func scrollToEnd(in window: NSWindow) {
        guard let textView = textView(in: window), let textLayoutManager = textView.textLayoutManager else { return }
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        textView.scrollToEndOfDocument(nil)
    }

    /// Курсор в название страницы.
    public static func focusTitle(in window: NSWindow) {
        textView(in: window)?.header.focusTitle()
    }

    private static func findTextView(in view: NSView) -> PageTextView? {
        if let textView = view as? PageTextView { return textView }
        return view.subviews.lazy.compactMap(findTextView).first
    }
}
