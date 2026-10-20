import AppKit
import NotesCore
import PageSearch
import SwiftUI
import VisualStyle

/// Показ окна «Переместить в…» карточкой над окном (research R9): у меню, из которого вызвано, — под `anchor`
/// (координаты экрана). Выбор, Esc, щелчок мимо и уход приложения в фон закрывают карточку.
@MainActor
public final class PagePickerController: NSObject, NSWindowDelegate {
    private var window: PagePickerWindow?
    public private(set) var model: PagePickerModel?
    /// Подписка снимается в `deinit` — он не привязан к главному потоку.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    public override init() {}

    public var isShown: Bool { window != nil }

    /// Место карточки в координатах экрана; `nil` — закрыта.
    public var cardFrame: NSRect? { window?.frame }

    /// Открыть для `subject`: недавние и поиск — из `store`, дерево — `tree` (без корзины).
    public func show(_ subject: PagePickerSubject, store: NotesStore, tree: PageTreeSnapshot, below anchor: NSRect, in parent: NSWindow,
                     onChoose: @escaping (PagePickerTarget) -> Void) {
        close()
        let recents = (try? store.recentPages(limit: PagePickerModel.recentLimit)) ?? []
        let search = PageSearch(store: store)
        let model = PagePickerModel(subject: subject, tree: tree, recentPages: recents) { query in
            ((try? search.results(for: query, in: tree)) ?? []).map(\.pageId)
        }
        model.onChoose = { [weak self] target in
            self?.close()
            onChoose(target)
        }
        model.onDismiss = { [weak self] in self?.close() }
        let host = NSHostingView(rootView: PagePickerView(model: model))
        let size = NSSize(width: PagePickerView.width, height: host.fittingSize.height)
        let window = PagePickerWindow(content: host)
        window.delegate = self
        window.setFrame(Self.card(size: size, below: anchor, within: parent.frame, screen: parent.screen?.visibleFrame), display: false)
        self.window = window
        self.model = model
        if PopupWindows.show(window, over: parent, makingKey: true) {
            window.makeFirstResponder(host)
        }
        observers.append(PopupWindows.onAppDeactivation { [weak self] in self?.close() })
        // Высота следует за списком (раскрытие, поиск): верх карточки остаётся на месте.
        observeHeight()
    }

    public func close() {
        guard let window else { return }
        let parent = window.parent
        window.delegate = nil
        parent?.removeChildWindow(window)
        window.orderOut(nil)
        self.window = nil
        model = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let parent, parent.isVisible { parent.makeKey() }
    }

    public func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func observeHeight() {
        withObservationTracking {
            _ = model?.rows
        } onChange: { [weak self] in
            Task { @MainActor in self?.fitHeight() }
        }
    }

    private func fitHeight() {
        guard let window, let host = window.contentView else { return }
        let height = host.fittingSize.height
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        window.setFrame(frame, display: true)
        observeHeight()
    }

    /// Под якорем на 4 пт, по левому краю якоря; у правого края окна — по правому; внизу экрана не помещается — над ним.
    static func card(size: NSSize, below anchor: NSRect, within bounds: NSRect, screen: NSRect?) -> NSRect {
        let spacing: CGFloat = 4
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - spacing - size.height)
        if origin.x + size.width > bounds.maxX { origin.x = anchor.maxX - size.width }
        origin.x = max(bounds.minX + spacing, min(origin.x, bounds.maxX - size.width - spacing))
        if let screen, origin.y < screen.minY { origin.y = anchor.maxY + spacing }
        return NSRect(origin: origin, size: size)
    }
}

/// Окно без рамки с карточкой; принимает ввод — в поле печатают.
@MainActor
final class PagePickerWindow: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isReleasedWhenClosed = false
        contentView = content
        setAccessibilityIdentifier("page-picker-window")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
