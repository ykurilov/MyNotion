import AppKit
import NotesCore
import UniformTypeIdentifiers
import VisualStyle

/// Окно «Сменить обложку» (contracts/pages-ui.md): вкладки «Галерея» и «Загрузить», справа «Убрать».
/// «Галерея» — раздел «Цвета и градиенты», плитки по 4 в ряд; «Загрузить» — кнопка «Загрузить файл» и место для
/// перетаскивания картинки из Finder. Esc, щелчок мимо и уход приложения в фон закрывают окно.
@MainActor
public final class CoverPickerController: NSObject, NSWindowDelegate {
    public enum Choice: Equatable {
        case gallery(String)
        case file(URL)
        case remove
    }

    private(set) var view: CoverPickerView?
    private var window: CoverPickerWindow?
    private var onChoose: ((Choice) -> Void)?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    public override init() {}

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    public var isShown: Bool { view != nil }

    /// Открыть под `anchor` («Сменить обложку», координаты экрана) над окном `parent`.
    public func show(below anchor: NSRect, in parent: NSWindow, tab: CoverPickerView.Tab = .gallery,
                     onChoose: @escaping (Choice) -> Void) {
        close()
        self.onChoose = onChoose
        let view = CoverPickerView(tab: tab)
        view.onChoose = { [weak self] choice in self?.choose(choice) }
        view.onUploadFile = { [weak self, weak parent] in
            guard let self, let parent else { return }
            self.close()
            Self.chooseFile(in: parent) { url in onChoose(.file(url)) }
        }
        view.onCancel = { [weak self] in self?.close() }
        // Окно шире карточки на поля тени с каждой стороны.
        let size = NSSize(width: view.fittingSize.width - 2 * CoverPickerView.shadowMargin,
                          height: view.fittingSize.height - 2 * CoverPickerView.shadowMargin)
        let card = Self.card(size: size, below: anchor, within: parent.frame, screen: parent.screen?.visibleFrame)
        let window = CoverPickerWindow(view: view)
        window.delegate = self
        window.setFrame(card.insetBy(dx: -CoverPickerView.shadowMargin, dy: -CoverPickerView.shadowMargin), display: false)
        self.view = view
        self.window = window
        PopupWindows.show(window, over: parent, makingKey: true)
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
        onChoose = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let parent, parent.isVisible { parent.makeKey() }
    }

    private func choose(_ choice: Choice) {
        let onChoose = onChoose
        close()
        onChoose?(choice)
    }

    public func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// «Загрузить файл»: системное окно выбора картинки листом над окном страницы.
    static func chooseFile(in window: NSWindow, onChoose: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Загрузить"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            onChoose(url)
        }
    }

    /// Карточка под кнопкой, правым краем к её правому краю (как у Notion); не помещается снизу — над кнопкой.
    static func card(size: NSSize, below anchor: NSRect, within bounds: NSRect, screen: NSRect?) -> NSRect {
        var origin = NSPoint(x: (anchor.maxX - size.width).rounded(), y: anchor.minY - 6 - size.height)
        if let screen, origin.y < screen.minY { origin.y = anchor.maxY + 6 }
        origin.x = max(bounds.minX + 8, min(origin.x, bounds.maxX - 8 - size.width))
        return NSRect(origin: origin, size: size)
    }
}

/// Карточка окна «Сменить обложку».
@MainActor
public final class CoverPickerView: NSView {
    public enum Tab: Equatable { case gallery, upload }

    static let shadowMargin: CGFloat = 24
    static let uploadHint = "Картинки шире 1500 пикселей смотрятся лучше. Не больше 100 МБ"

    private(set) var tab: Tab
    var onChoose: ((CoverPickerController.Choice) -> Void)?
    var onUploadFile: (() -> Void)?
    var onCancel: (() -> Void)?

    let galleryTab = CoverPickerTabButton(title: "Галерея", identifier: "cover-tab-gallery")
    let uploadTab = CoverPickerTabButton(title: "Загрузить", identifier: "cover-tab-upload")
    let removeButton = CoverPickerTabButton(title: "Убрать", identifier: "cover-remove")
    private let sectionTitle = NSTextField(labelWithString: "Цвета и градиенты")
    private(set) var tiles: [CoverGalleryTile] = []
    let uploadButton = CoverUploadButton()
    private let uploadHintLabel = NSTextField(wrappingLabelWithString: CoverPickerView.uploadHint)
    /// Над окном тащат картинку из Finder.
    private(set) var isDropTargeted = false { didSet { needsDisplay = true } }

    init(tab: Tab) {
        self.tab = tab
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("cover-picker")
        for button in [galleryTab, uploadTab, removeButton] { addSubview(button) }
        galleryTab.onPress = { [weak self] in self?.select(.gallery) }
        uploadTab.onPress = { [weak self] in self?.select(.upload) }
        removeButton.onPress = { [weak self] in self?.onChoose?(.remove) }
        sectionTitle.font = .systemFont(ofSize: Typography.popupMenuSectionHeader.fontSize, weight: .medium)
        sectionTitle.textColor = Palette.textSecondary
        addSubview(sectionTitle)
        tiles = CoverGallery.items.map { item in
            let tile = CoverGalleryTile(item: item)
            tile.onPress = { [weak self] in self?.onChoose?(.gallery(item.id)) }
            addSubview(tile)
            return tile
        }
        uploadButton.onPress = { [weak self] in self?.onUploadFile?() }
        addSubview(uploadButton)
        uploadHintLabel.font = .systemFont(ofSize: Typography.popupMenuShortcut.fontSize)
        uploadHintLabel.textColor = Palette.textSecondary
        uploadHintLabel.alignment = .center
        addSubview(uploadHintLabel)
        registerForDraggedTypes([.fileURL])
        select(tab)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public override var isFlipped: Bool { true }

    func select(_ tab: Tab) {
        self.tab = tab
        galleryTab.isSelected = tab == .gallery
        uploadTab.isSelected = tab == .upload
        sectionTitle.isHidden = tab != .gallery
        tiles.forEach { $0.isHidden = tab != .gallery }
        uploadButton.isHidden = tab != .upload
        uploadHintLabel.isHidden = tab != .upload
        needsLayout = true
        needsDisplay = true
    }

    private var card: NSRect { bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin) }

    private var tileSize: NSSize {
        let metrics = Metrics.PageCover.self
        let inner = metrics.pickerWidth - 2 * metrics.pickerPadding
        let width = ((inner - CGFloat(metrics.pickerTilesPerRow - 1) * metrics.pickerTileSpacing) / CGFloat(metrics.pickerTilesPerRow)).rounded(.down)
        return NSSize(width: width, height: metrics.pickerTileHeight)
    }

    public override var fittingSize: NSSize {
        let metrics = Metrics.PageCover.self
        let rows = (CoverGallery.items.count + metrics.pickerTilesPerRow - 1) / metrics.pickerTilesPerRow
        let gallery = metrics.pickerTabHeight + metrics.pickerPadding + 20
            + CGFloat(rows) * (metrics.pickerTileHeight + metrics.pickerTileSpacing) + metrics.pickerPadding
        return NSSize(width: metrics.pickerWidth + 2 * Self.shadowMargin, height: gallery + 2 * Self.shadowMargin)
    }

    public override func layout() {
        super.layout()
        let metrics = Metrics.PageCover.self
        let card = card
        var x = card.minX + metrics.pickerPadding - 6
        for button in [galleryTab, uploadTab] {
            button.frame = NSRect(x: x, y: card.minY, width: button.fittingWidth, height: metrics.pickerTabHeight)
            x += button.fittingWidth + 2
        }
        removeButton.frame = NSRect(x: card.maxX - metrics.pickerPadding + 6 - removeButton.fittingWidth, y: card.minY,
                                    width: removeButton.fittingWidth, height: metrics.pickerTabHeight)
        let top = card.minY + metrics.pickerTabHeight + metrics.pickerPadding
        sectionTitle.sizeToFit()
        sectionTitle.frame.origin = NSPoint(x: card.minX + metrics.pickerPadding, y: top)
        let tile = tileSize
        for (index, view) in tiles.enumerated() {
            let row = index / metrics.pickerTilesPerRow, column = index % metrics.pickerTilesPerRow
            view.frame = NSRect(x: card.minX + metrics.pickerPadding + CGFloat(column) * (tile.width + metrics.pickerTileSpacing),
                                y: top + 20 + CGFloat(row) * (tile.height + metrics.pickerTileSpacing), width: tile.width, height: tile.height)
        }
        let inner = card.width - 2 * metrics.pickerPadding
        uploadButton.frame = NSRect(x: card.minX + metrics.pickerPadding, y: top, width: inner, height: 32)
        let hint = uploadHintLabel.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude))
        uploadHintLabel.frame = NSRect(x: card.minX + metrics.pickerPadding, y: uploadButton.frame.maxY + 12, width: inner, height: hint.height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        PopupSurface.draw(card: card)
        Palette.popupDivider.setFill()
        NSRect(x: card.minX, y: card.minY + Metrics.PageCover.pickerTabHeight - 1, width: card.width, height: 1).fill()
        if let selected = [galleryTab, uploadTab].first(where: \.isSelected) {
            Palette.textPrimary.setFill()
            NSRect(x: selected.frame.minX + 6, y: selected.frame.maxY - 2, width: selected.frame.width - 12, height: 2).fill()
        }
        if isDropTargeted {
            let path = NSBezierPath(roundedRect: card.insetBy(dx: 2, dy: 2), xRadius: Metrics.PopupMenu.cornerRadius,
                                    yRadius: Metrics.PopupMenu.cornerRadius)
            Palette.focusRing.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    public override func cancelOperation(_ sender: Any?) { onCancel?() }

    // MARK: Перетаскивание из Finder

    private func droppedImage(_ info: any NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard droppedImage(sender) != nil else { return [] }
        if tab != .upload { select(.upload) }
        isDropTargeted = true
        return .copy
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) { isDropTargeted = false }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTargeted = false
        guard let url = droppedImage(sender) else { return false }
        onChoose?(.file(url))
        return true
    }
}

/// Плитка галереи: цвет или градиент, под мышью — рамка.
@MainActor
final class CoverGalleryTile: NSView {
    let item: CoverGallery.Item
    private let image: CGImage?
    var onPress: (() -> Void)?
    private var isPointerInside = false { didSet { needsDisplay = true } }

    init(item: CoverGallery.Item) {
        self.item = item
        image = CoverGallery.image(for: item)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
        setAccessibilityIdentifier("cover-gallery-\(item.id)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    func press() { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true }
    override func mouseExited(with event: NSEvent) { isPointerInside = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 3
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let image, let context = NSGraphicsContext.current?.cgContext {
            let rect = CoverImagePlacement.rect(imageAspect: item.aspectRatio, in: bounds, offset: PageCover.defaultOffset)
            context.translateBy(x: 0, y: rect.maxY + rect.minY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        if isPointerInside {
            NSColor(white: 0, alpha: 0.15).setFill()
            path.fill()
        }
    }
}

/// Вкладка окна («Галерея», «Загрузить») и «Убрать»: надпись 14, выбранная — тёмная, остальные серые.
@MainActor
final class CoverPickerTabButton: NSView {
    let title: String
    var onPress: (() -> Void)?
    var isSelected = false {
        didSet { needsDisplay = true; setAccessibilityValue(isSelected ? "1" : "0") }
    }
    private var isPointerInside = false { didSet { needsDisplay = true } }

    init(title: String, identifier: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityIdentifier(identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var attributedTitle: NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: Typography.popupMenuTitle.fontSize, weight: .medium),
            .foregroundColor: isSelected ? Palette.textPrimary : Palette.textSecondary,
        ])
    }

    var fittingWidth: CGFloat { ceil(attributedTitle.size().width) + 16 }

    func press() { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true }
    override func mouseExited(with event: NSEvent) { isPointerInside = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPointerInside {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 6, width: bounds.width - 4, height: bounds.height - 12), xRadius: 4, yRadius: 4).fill()
        }
        let text = attributedTitle
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: ((bounds.height - size.height) / 2).rounded()))
    }
}

/// «Загрузить файл»: кнопка во всю ширину с рамкой, как у Notion.
@MainActor
final class CoverUploadButton: NSView {
    var onPress: (() -> Void)?
    private var isPointerInside = false { didSet { needsDisplay = true } }
    private let title = NSAttributedString(string: "Загрузить файл", attributes: [
        .font: NSFont.systemFont(ofSize: Typography.popupMenuTitle.fontSize, weight: .medium), .foregroundColor: Palette.textPrimary,
    ])

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Загрузить файл")
        setAccessibilityIdentifier("cover-upload-file")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    func press() { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true }
    override func mouseExited(with event: NSEvent) { isPointerInside = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        (isPointerInside ? Palette.hoverBackground : NSColor.clear).setFill()
        path.fill()
        Palette.searchFieldBorder.setStroke()
        path.stroke()
        let size = title.size()
        title.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: ((bounds.height - size.height) / 2).rounded()))
    }
}

/// Окно без рамки с карточкой; принимает клавиши (Esc).
@MainActor
final class CoverPickerWindow: NSPanel {
    init(view: CoverPickerView) {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        contentView = view
    }

    override var canBecomeKey: Bool { true }
}
