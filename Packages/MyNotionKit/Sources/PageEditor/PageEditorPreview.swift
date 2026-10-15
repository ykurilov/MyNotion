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

    /// Режим выделения блоков: блоки от `first` до `last`, как после Esc или протяжки с поля.
    @discardableResult
    public static func selectWholeBlocks(from first: UUID, through last: UUID, in window: NSWindow) -> Bool {
        guard let textView = textView(in: window), let firstIndex = textView.document.index(ofBlock: first),
              let lastIndex = textView.document.index(ofBlock: last) else { return false }
        window.makeFirstResponder(textView)
        textView.selectBlocks(anchor: firstIndex, head: lastIndex)
        return true
    }

    /// Выделить текст блоков от начала `first` до конца `last`.
    @discardableResult
    public static func selectBlocks(from first: UUID, through last: UUID, in window: NSWindow) -> Bool {
        guard let textView = textView(in: window), let firstIndex = textView.document.index(ofBlock: first),
              let lastIndex = textView.document.index(ofBlock: last) else { return false }
        window.makeFirstResponder(textView)
        let start = textView.mapper.paragraphStart(ofBlockAt: firstIndex)
        let end = textView.mapper.paragraphStart(ofBlockAt: lastIndex) + (textView.document.blocks[lastIndex].text.string as NSString).length
        textView.setSelectedRange(NSRange(location: start, length: end - start))
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
        textView.selectBlockAndOpenMenu(blockId, below: handleOnScreen)
        return true
    }

    /// Взять блок за «⋮⋮» и сдвинуть мышь на `offset` (вниз — плюс), не отпуская кнопку: идёт перетаскивание.
    @discardableResult
    public static func beginDrag(ofBlock blockId: UUID, by offset: CGSize, in window: NSWindow) -> Bool {
        guard hoverBlock(blockId, in: window), let textView = textView(in: window) else { return false }
        let handle = textView.blockHandles.dragHandle
        let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        for step in 0...2 {
            let fraction = CGFloat(step) / 2
            let point = NSPoint(x: start.x + offset.width * fraction, y: start.y - offset.height * fraction)
            guard let event = NSEvent.mouseEvent(with: step == 0 ? .leftMouseDown : .leftMouseDragged, location: point, modifierFlags: [],
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1) else { return false }
            if step == 0 { handle.mouseDown(with: event) } else { handle.mouseDragged(with: event) }
        }
        return !textView.blockHandles.dragGhost.isHidden
    }

    /// Отменить перетаскивание, как Esc, и убрать ручки.
    public static func cancelDrag(in window: NSWindow) {
        guard let textView = textView(in: window) else { return }
        textView.blockHandles.cancelDrag()
        textView.hideBlockHandles()
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
