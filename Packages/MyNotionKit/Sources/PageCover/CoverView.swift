import AppKit
import ImageIO
import NotesCore
import VisualStyle

/// Обложка страницы в месте «обложка» шапки (contracts/pages-ui.md, «Шапка страницы»): во всю ширину области
/// страницы, картинка заполняет по ширине, по вертикали видна часть по `offset`. Своя картинка — уменьшенная копия
/// по ширине окна × 2 (ImageIO, research R1), полная в память не читается; пока файла нет — заглушка.
/// При наведении справа вверху — тёмная группа «Сменить» и «Переместить», как у Notion 7.39; в режиме «Переместить»
/// картинку тянут мышью, там же «Сохранить положение» и «Отмена».
@MainActor
public final class CoverView: NSView {
    public private(set) var cover: PageCover
    /// Копия файла обложки на этом Mac; `nil` — ещё не пришёл.
    private let fileURL: (UUID) -> URL?
    /// «Сменить»: группа кнопок в координатах экрана, под ней — окно выбора.
    public var onChangeCover: ((NSRect) -> Void)?
    /// «Сохранить положение».
    public var onSaveOffset: ((Double) -> Void)?

    let buttons = CoverButtonGroup()
    let changeButton = CoverButton(title: "Сменить", identifier: "change-page-cover")
    let repositionButton = CoverButton(title: "Переместить", identifier: "reposition-page-cover")
    let saveButton = CoverButton(title: "Сохранить положение", identifier: "save-cover-position")
    let cancelButton = CoverButton(title: "Отмена", identifier: "cancel-cover-position")
    let repositionHint = CoverHintLabel(text: "Перетащите картинку, чтобы сдвинуть")
    let copyHint = CoverHintLabel(text: "", identifier: "cover-copy-progress")

    /// Своя картинка копируется (доля 0…1): вместо обложки — заглушка с ходом копирования, как у файла 002;
    /// `nil` — не копируется.
    public var copyProgress: Double? {
        didSet {
            guard copyProgress != oldValue else { return }
            updateButtons()
            needsDisplay = true
        }
    }

    public private(set) var repositioning: CoverRepositionMode?
    public var isHovered = false {
        didSet { if isHovered != oldValue { updateButtons() } }
    }

    /// Картинка галереи (сетка цветов) или уменьшенная копия файла; `nil` — заглушка.
    private(set) var image: CGImage?
    /// Картинка или градиент нарисованы (не заглушка).
    public var hasImage: Bool { image != nil }
    /// Ширина к высоте того, что рисуется: у галереи — исходной картинки Notion, у файла — самой картинки.
    private var imageAspect: CGFloat = 1
    /// Файл, чья копия загружена или грузится, и её ширина в пикселях.
    private var loadedFile: (id: UUID, pixelWidth: CGFloat)?
    private var loadGeneration = 0
    nonisolated(unsafe) private var availabilityObserver: NSObjectProtocol?

    public init(cover: PageCover, fileURL: @escaping (UUID) -> URL?) {
        self.cover = cover
        self.fileURL = fileURL
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Обложка")
        setAccessibilityIdentifier("page-cover")
        addSubview(repositionHint)
        addSubview(copyHint)
        addSubview(buttons)
        changeButton.onPress = { [weak self] in self?.changeCover() }
        repositionButton.onPress = { [weak self] in self?.beginReposition() }
        saveButton.onPress = { [weak self] in self?.saveReposition() }
        cancelButton.onPress = { [weak self] in self?.cancelReposition() }
        availabilityObserver = NotificationCenter.default.addObserver(forName: AttachmentRef.availabilityDidChange, object: nil,
                                                                      queue: .main) { [weak self] note in
            let id = note.object as? UUID
            MainActor.assumeIsolated {
                guard let self, let id, self.cover.attachment?.id == id, self.image == nil else { return }
                self.loadedFile = nil
                self.reloadImage()
            }
        }
        updateButtons()
        reloadImage()
    }

    deinit {
        if let availabilityObserver { NotificationCenter.default.removeObserver(availabilityObserver) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public override var isFlipped: Bool { true }

    /// Обложка страницы сменилась (другая картинка, сдвиг, правка с другого Mac).
    public func show(_ cover: PageCover) {
        guard cover != self.cover else { return }
        let sourceChanged = cover.source != self.cover.source
        self.cover = cover
        if repositioning != nil { repositioning = nil; updateButtons() }
        if sourceChanged { reloadImage() }
        needsDisplay = true
    }

    // MARK: Картинка

    private func reloadImage() {
        loadGeneration += 1
        switch cover.source {
        case .gallery(let id):
            loadedFile = nil
            if let item = CoverGallery.item(id) {
                image = CoverGallery.image(for: item)
                imageAspect = item.aspectRatio
            } else {
                image = nil
            }
            setAccessibilityValue(id)
            needsDisplay = true
        case .file(let ref):
            setAccessibilityValue(ref.name)
            loadThumbnail(of: ref)
        case .unknown:
            // Вид обложки от новой версии — заглушка.
            loadedFile = nil
            image = nil
            setAccessibilityValue(nil)
            needsDisplay = true
        }
    }

    /// Нужная ширина копии в пикселях: ширина вида на экране.
    private var wantedPixelWidth: CGFloat {
        max(bounds.width, 800) * (window?.backingScaleFactor ?? 2)
    }

    private func loadThumbnail(of ref: AttachmentRef) {
        guard let url = fileURL(ref.id) else {
            image = nil
            loadedFile = nil
            needsDisplay = true
            return
        }
        let width = wantedPixelWidth
        if let loadedFile, loadedFile.id == ref.id, loadedFile.pixelWidth * 1.25 >= width { return }
        if loadedFile?.id != ref.id { image = nil }
        loadedFile = (ref.id, width)
        let generation = loadGeneration
        Task.detached(priority: .userInitiated) {
            let thumbnail = CoverThumbnail.make(from: url, pixelWidth: width)
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration, let thumbnail else { return }
                self.image = thumbnail
                self.imageAspect = CGFloat(thumbnail.width) / CGFloat(max(thumbnail.height, 1))
                self.needsDisplay = true
            }
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let ref = cover.attachment { loadThumbnail(of: ref) }
    }

    /// Насколько картинка выше рамки — столько её можно двигать.
    private var spareHeight: CGFloat {
        CoverImagePlacement.rect(imageAspect: imageAspect, in: bounds, offset: 0).height - bounds.height
    }

    private var shownOffset: Double { repositioning?.offset ?? cover.offset }

    public override func draw(_ dirtyRect: NSRect) {
        guard copyProgress == nil, let image, let context = NSGraphicsContext.current?.cgContext else {
            Palette.placeholder.setFill()
            bounds.fill()
            return
        }
        let rect = CoverImagePlacement.rect(imageAspect: imageAspect, in: bounds, offset: shownOffset)
        context.saveGState()
        context.clip(to: bounds)
        // Вид перевёрнут, а CGImage рисуется снизу вверх: перевернуть место картинки.
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.restoreGState()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let grew = newSize.width > frame.width
        super.setFrameSize(newSize)
        if grew, let ref = cover.attachment { loadThumbnail(of: ref) }
    }

    // MARK: Кнопки

    private func updateButtons() {
        let inMode = repositioning != nil
        buttons.setButtons(inMode ? [saveButton, cancelButton] : [changeButton, repositionButton])
        buttons.isHidden = copyProgress != nil || (!inMode && !isHovered)
        repositionHint.isHidden = !inMode
        copyHint.isHidden = copyProgress == nil
        if let copyProgress { copyHint.string = "Копируется… \(Int((copyProgress * 100).rounded(.down))) %" }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let size = buttons.fittingSize
        let inset = Metrics.PageCover.buttonInset
        buttons.frame = NSRect(x: (bounds.maxX - inset - size.width).rounded(), y: inset, width: size.width, height: size.height)
        let hint = repositionHint.fittingSize
        repositionHint.frame = NSRect(x: (bounds.midX - hint.width / 2).rounded(), y: (bounds.midY - hint.height / 2).rounded(),
                                      width: hint.width, height: hint.height)
        let copy = copyHint.fittingSize
        copyHint.frame = NSRect(x: (bounds.midX - copy.width / 2).rounded(), y: (bounds.midY - copy.height / 2).rounded(),
                                width: copy.width, height: copy.height)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    public override func cursorUpdate(with event: NSEvent) { (repositioning == nil ? NSCursor.iBeam : NSCursor.openHand).set() }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }

    public func changeCover() {
        guard let window else { onChangeCover?(.zero); return }
        onChangeCover?(window.convertToScreen(buttons.convert(buttons.bounds, to: nil)))
    }

    // MARK: «Переместить»

    public func beginReposition() {
        repositioning = CoverRepositionMode(offset: cover.offset)
        updateButtons()
        window?.invalidateCursorRects(for: self)
    }

    public func cancelReposition() {
        repositioning = nil
        updateButtons()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    public func saveReposition() {
        guard let repositioning else { return }
        self.repositioning = nil
        cover.offset = repositioning.offset
        updateButtons()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        if repositioning.offset != repositioning.originalOffset { onSaveOffset?(repositioning.offset) }
    }

    /// Сдвиг во время «Переместить» — для тестов и доступности: как будто картинку протянули на `dy`.
    func drag(by dy: CGFloat) {
        repositioning?.beginDrag(atY: 0)
        repositioning?.drag(toY: dy, spare: spareHeight)
        repositioning?.endDrag()
        needsDisplay = true
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: repositioning == nil ? .iBeam : .openHand)
    }

    public override func mouseDown(with event: NSEvent) {
        guard repositioning != nil else { return super.mouseDown(with: event) }
        repositioning?.beginDrag(atY: convert(event.locationInWindow, from: nil).y)
        NSCursor.closedHand.push()
    }

    public override func mouseDragged(with event: NSEvent) {
        guard repositioning != nil else { return }
        repositioning?.drag(toY: convert(event.locationInWindow, from: nil).y, spare: spareHeight)
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        guard repositioning != nil else { return super.mouseUp(with: event) }
        repositioning?.endDrag()
        NSCursor.pop()
        NSCursor.openHand.set()
    }

    /// Вне режима «Переместить» щелчок по обложке ничего не делает, но и текст под ней не получает.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
}

/// Уменьшенная копия картинки по ширине (ImageIO): полная картинка в память не читается.
enum CoverThumbnail {
    static func make(from url: URL, pixelWidth: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var width = (properties?[kCGImagePropertyPixelWidth] as? CGFloat) ?? pixelWidth
        var height = (properties?[kCGImagePropertyPixelHeight] as? CGFloat) ?? pixelWidth
        if let orientation = properties?[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        // Длинная сторона копии — чтобы по ширине вышло `pixelWidth`, не больше исходника.
        let longest = min(max(width, height), pixelWidth * max(1, height / max(width, 1)))
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, longest),
        ] as CFDictionary)
    }
}

/// Кнопки на обложке одной тёмной группой, как у Notion: общая подложка без черт между «Сменить» и «Переместить».
@MainActor
final class CoverButtonGroup: NSView {
    private(set) var items: [CoverButton] = []

    override var isFlipped: Bool { true }

    func setButtons(_ buttons: [CoverButton]) {
        guard buttons.map(ObjectIdentifier.init) != items.map(ObjectIdentifier.init) else { return }
        items.forEach { $0.removeFromSuperview() }
        items = buttons
        buttons.forEach(addSubview)
        needsLayout = true
        needsDisplay = true
    }

    override var fittingSize: NSSize {
        NSSize(width: items.reduce(0) { $0 + $1.fittingWidth } + 2 * Metrics.PageCover.buttonGroupPadding, height: Metrics.PageCover.buttonHeight)
    }

    override func layout() {
        super.layout()
        var x = Metrics.PageCover.buttonGroupPadding
        for item in items {
            item.frame = NSRect(x: x, y: 2, width: item.fittingWidth, height: bounds.height - 4)
            x += item.fittingWidth
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Metrics.PageCover.buttonGroupCornerRadius
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        Palette.coverButtonBackground.setFill()
        path.fill()
        Palette.coverButtonBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Кнопка группы на обложке: серая надпись 12, под мышью — подложка.
@MainActor
final class CoverButton: NSView {
    let title: String
    var onPress: (() -> Void)?
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
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: Metrics.PageCover.buttonFontSize, weight: .medium),
                                                       .foregroundColor: Palette.coverButtonText])
    }

    var fittingWidth: CGFloat {
        ceil(attributedTitle.size().width) + 2 * Metrics.PageCover.buttonHorizontalPadding
    }

    func press() { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseEntered(with event: NSEvent) { isPointerInside = true }
    override func mouseExited(with event: NSEvent) { isPointerInside = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPointerInside {
            Palette.coverButtonHover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        }
        let text = attributedTitle
        let size = text.size()
        text.draw(at: NSPoint(x: Metrics.PageCover.buttonHorizontalPadding, y: ((bounds.height - size.height) / 2).rounded()))
    }
}

/// Подсказка режима «Переместить» по центру обложки: белая надпись на тёмной полупрозрачной подложке (≈ по Notion).
@MainActor
final class CoverHintLabel: NSView {
    private var text: NSAttributedString

    init(text: String, identifier: String = "cover-reposition-hint") {
        self.text = Self.attributed(text)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        setAccessibilityIdentifier(identifier)
    }

    var string: String {
        get { text.string }
        set {
            guard newValue != text.string else { return }
            text = Self.attributed(newValue)
            setAccessibilityLabel(newValue)
            needsDisplay = true
        }
    }

    private static func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: Metrics.PageCover.buttonFontSize, weight: .medium), .foregroundColor: NSColor.white,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        NSSize(width: ceil(text.size().width) + 2 * 12, height: Metrics.PageCover.repositionHintHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.4).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.PageCover.buttonGroupCornerRadius, yRadius: Metrics.PageCover.buttonGroupCornerRadius).fill()
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: ((bounds.height - size.height) / 2).rounded()))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
