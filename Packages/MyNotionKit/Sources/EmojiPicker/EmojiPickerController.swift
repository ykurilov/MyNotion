import AppKit
import VisualStyle

/// Окно выбора иконки-эмодзи, как у Notion (FR-034): открывается под иконкой страницы — в шапке или в боковой панели.
/// Выбор, «Случайная» и «Убрать» сообщаются в `onChoose` (`nil` — убрать); Esc, щелчок мимо и уход приложения
/// в фон закрывают окно. Выбранное попадает в «Недавние».
@MainActor
public final class EmojiPickerController: NSObject, NSWindowDelegate {
    private let catalog: EmojiCatalog
    private let recents: RecentEmojis
    private(set) var view: EmojiPickerView?
    private var window: EmojiPickerWindow?
    private var onChoose: ((String?) -> Void)?
    private var observers: [NSObjectProtocol] = []
    /// Место карточки без тени, в координатах экрана; `nil` — окно закрыто.
    public private(set) var cardFrame: NSRect?

    public init(catalog: EmojiCatalog = .shared, recents: RecentEmojis = RecentEmojis()) {
        self.catalog = catalog
        self.recents = recents
    }

    public var isShown: Bool { view != nil }

    /// Текст в поле поиска открытого окна.
    public var query: String {
        get { view?.query ?? "" }
        set { view?.query = newValue }
    }

    /// Открыть под `anchor` (иконка, координаты экрана) над окном `parent`. Невидимый `parent` — окно на экран не выходит.
    /// `allowsRemoving: false` — без «Убрать»: иконка обязательна (выноска).
    public func show(below anchor: NSRect, in parent: NSWindow, allowsRemoving: Bool = true, onChoose: @escaping (String?) -> Void) {
        close()
        self.onChoose = onChoose
        let view = EmojiPickerView(catalog: catalog, recents: recents.emojis)
        view.removeButton.isHidden = !allowsRemoving
        view.onChoose = { [weak self] emoji, closes in self?.choose(emoji, closes: closes) }
        view.onCancel = { [weak self] in self?.close() }
        let size = NSSize(width: Metrics.EmojiPicker.width, height: Metrics.EmojiPicker.height)
        let card = EmojiPickerPlacement.card(size: size, below: anchor, within: parent.frame, screen: parent.screen?.visibleFrame)
        let window = EmojiPickerWindow(view: view)
        window.delegate = self
        window.setFrame(card.insetBy(dx: -EmojiPickerView.shadowMargin, dy: -EmojiPickerView.shadowMargin), display: false)
        self.view = view
        self.window = window
        cardFrame = card
        if PopupWindows.show(window, over: parent, makingKey: true) {
            window.makeFirstResponder(view.searchField)
        }
        observers.append(PopupWindows.onAppDeactivation { [weak self] in self?.close() })
    }

    public func close() {
        guard let window else { return }
        let parent = window.parent
        window.delegate = nil
        parent?.removeChildWindow(window)
        window.orderOut(nil)
        self.window = nil
        view = nil
        cardFrame = nil
        onChoose = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let parent, parent.isVisible { parent.makeKey() }
    }

    private func choose(_ emoji: String?, closes: Bool) {
        let onChoose = onChoose
        if let emoji, closes { recents.add(emoji) }
        if closes { close() }
        onChoose?(emoji)
    }

    public func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// Место карточки: по середине иконки под ней на `anchorSpacing`; внизу экрана не помещается — над иконкой;
/// по ширине — в пределах окна `within`. Координаты экрана.
enum EmojiPickerPlacement {
    static func card(size: NSSize, below anchor: NSRect, within bounds: NSRect, screen: NSRect?) -> NSRect {
        let spacing = Metrics.EmojiPicker.anchorSpacing
        var origin = NSPoint(x: (anchor.midX - size.width / 2).rounded(), y: anchor.minY - spacing - size.height)
        if let screen, origin.y < screen.minY { origin.y = anchor.maxY + spacing }
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - size.width))
        return NSRect(origin: origin, size: size)
    }
}

/// Окно без рамки с карточкой; принимает ввод — в поле поиска печатают.
@MainActor
final class EmojiPickerWindow: NSPanel {
    let pickerView: EmojiPickerView

    init(view: EmojiPickerView) {
        pickerView = view
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isReleasedWhenClosed = false
        contentView = view
        setAccessibilityIdentifier("emoji-picker")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        _ = pickerView.handleCommand(#selector(NSResponder.cancelOperation(_:)))
    }
}
