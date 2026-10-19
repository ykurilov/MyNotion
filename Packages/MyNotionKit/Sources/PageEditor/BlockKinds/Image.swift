import AppKit
import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    /// Картинка (US5, FR-107): по ширине колонки, ширина 10–100 % ручками по бокам, подпись в `text`.
    /// Вставка — перетаскиванием из Finder, ⌘V, «/» → «Картинка» («Выбрать файл…» или ссылка).
    static let image = BlockKindDescriptor(
        kind: .image,
        menuItem: PopupMenuItem(title: "Картинка", icon: .symbol("photo"), keywords: ["image", "изображение", "фото", "картинка", "picture"],
                                action: .setKind(.image)),
        gallerySamples: [
            BlockGallerySample(id: "media-image", summary: "Картинка во всю колонку с подписью и картинка на 50 %",
                               blocks: [
                                   .init(.paragraph, "Абзац над картинкой"),
                                   .init(.image, "Закат над морем", props: MediaSamples.image(name: "закат.png", width: nil)),
                                   .init(.image, props: MediaSamples.image(name: "схема.png", width: 0.5)),
                                   .init(.paragraph, "Абзац под картинкой"),
                               ]),
            BlockGallerySample(id: "media-placeholders",
                               summary: "Заглушки: «Загружается…», «Ждёт отправки с другого Mac», файл, который копируется",
                               blocks: [
                                   .init(.image, props: MediaSamples.image(name: MediaSamples.downloadingName, width: nil)),
                                   .init(.image, props: MediaSamples.image(name: MediaSamples.waitingName, width: 0.6)),
                                   .init(.file, props: MediaSamples.file(name: MediaSamples.copyingName, byteCount: 84_000_000,
                                                                         contentType: "com.apple.quicktime-movie")),
                               ]),
        ],
        // Богатая страница (quickstart.md): 20 картинок.
        richPageBlocks: (1...20).map { number in
            RichBlockSpec(.image, number.isMultiple(of: 4) ? "Подпись картинки \(number)" : "",
                          props: MediaSamples.image(name: "картинка-\(number).png", width: number.isMultiple(of: 3) ? 0.5 : nil))
        }
    )
}

/// Вид картинки: уменьшенная картинка по центру колонки, под мышью — ручки ширины и «⋯»; пока файла нет — заглушка.
@MainActor
final class ImageBlockView: MediaBlockView {
    private let availability: MediaAvailability
    private let imageLayerView = MediaSurfaceView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private var handles: [NSView] = []
    private var menuButton: MediaOverlayButton?
    private var captionField: MediaCaptionField?
    /// Доля колонки во время перетаскивания ручки.
    private var liveWidthFraction: Double?
    private var isEditingCaption = false

    /// Надпись заглушки: «имя — Загружается…».
    var statusText: String? {
        guard availability.fileURL == nil else { return nil }
        return "\(block.props.attachment?.name ?? "Картинка") — \(availability.statusText)"
    }

    override init(block: Block, width: CGFloat) {
        availability = MediaBlocks.availability(of: block.props.attachment)
        super.init(block: block, width: width)
        setAccessibilityIdentifier("image-block")
        addSubview(imageLayerView)
        if let status = statusText {
            imageLayerView.fill = Palette.hoverBackground
            placeholderLabel.stringValue = status
            placeholderLabel.font = .systemFont(ofSize: Metrics.Media.captionFontSize)
            placeholderLabel.textColor = Palette.textSecondary
            placeholderLabel.alignment = .center
            placeholderLabel.lineBreakMode = .byTruncatingMiddle
            addSubview(placeholderLabel)
        }
        if !block.text.string.isEmpty { showCaptionField(focus: false) }
        frame.size.height = Self.contentHeight(for: block, width: width) + 2 * Metrics.Media.verticalPadding
        loadImage()
    }

    // MARK: Размеры

    static func clampedWidth(_ fraction: Double) -> Double {
        min(1, max(Metrics.Media.minimumWidthFraction, fraction))
    }

    static func imageSize(for block: Block, width: CGFloat, fraction: Double? = nil) -> NSSize {
        let imageWidth = (width * clampedWidth(fraction ?? block.props.width ?? 1)).rounded()
        let aspect = block.props.pixelSize.map { CGFloat($0.height) / CGFloat(max(1, $0.width)) } ?? Metrics.Media.defaultAspectRatio
        return NSSize(width: imageWidth, height: (imageWidth * aspect).rounded())
    }

    /// Высота без полей: картинка и, если есть, подпись.
    static func contentHeight(for block: Block, width: CGFloat) -> CGFloat {
        let caption = !block.text.string.isEmpty || MediaCaptionEditing.blockId == block.id
        return imageSize(for: block, width: width).height + (caption ? Metrics.Media.captionHeight : 0)
    }

    override func layout() {
        super.layout()
        let size = Self.imageSize(for: block, width: bounds.width, fraction: liveWidthFraction)
        let imageFrame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: Metrics.Media.verticalPadding,
                                width: size.width, height: size.height)
        imageLayerView.frame = imageFrame
        placeholderLabel.frame = NSRect(x: imageFrame.minX + 12, y: imageFrame.midY - 10, width: max(0, imageFrame.width - 24), height: 20)
        let inset = Metrics.Media.resizeHandleInset
        for (index, handle) in handles.enumerated() {
            let x = index == 0 ? imageFrame.minX + inset : imageFrame.maxX - inset - Metrics.Media.resizeHandleWidth
            handle.frame = NSRect(x: x, y: imageFrame.midY - Metrics.Media.resizeHandleHeight / 2,
                                  width: Metrics.Media.resizeHandleWidth, height: Metrics.Media.resizeHandleHeight)
        }
        menuButton?.frame.origin = NSPoint(x: imageFrame.maxX - Metrics.Media.menuButtonInset - Metrics.Media.menuButtonSize,
                                           y: imageFrame.minY + Metrics.Media.menuButtonInset)
        captionField?.frame = NSRect(x: imageFrame.minX, y: imageFrame.maxY + Metrics.Media.captionSpacing,
                                     width: imageFrame.width, height: Metrics.Media.captionLineHeight)
    }

    // MARK: Картинка

    private func loadImage() {
        guard let url = availability.fileURL else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = Int(Self.imageSize(for: block, width: bounds.width).width * scale)
        if let image = ImageThumbnailCache.shared.cached(url, maxPixelSize: pixels) {
            imageLayerView.image = image
            return
        }
        Task { [weak self] in
            let image = await ImageThumbnailCache.shared.thumbnail(url, maxPixelSize: pixels)
            self?.imageLayerView.image = image
        }
    }

    /// Файл пришёл или сменил состояние: вид заново на том же месте, высота строки та же.
    override func availabilityDidChange() {
        rebuild()
    }

    // MARK: Под мышью

    override func hoverDidChange() {
        if isHovered, handles.isEmpty, availability.fileURL != nil {
            handles = (0..<2).map { _ in ResizeHandle(owner: self) }
            handles.forEach(addSubview)
            let button = MediaOverlayButton(symbol: "ellipsis", size: Metrics.Media.menuButtonSize) { [weak self] in
                guard let self, let button = self.menuButton else { return }
                self.showMenu(from: button)
            }
            addSubview(button)
            menuButton = button
            needsLayout = true
        } else if !isHovered, liveWidthFraction == nil {
            handles.forEach { $0.removeFromSuperview() }
            handles = []
            menuButton?.removeFromSuperview()
            menuButton = nil
        }
    }

    override func menuItems() -> [NSMenuItem] {
        var items = [menuItem("Подпись") { [weak self] in self?.beginCaption() }]
        if let url = availability.fileURL {
            items.append(menuItem("Скачать") { MediaFileActions.saveCopy(of: url) })
            items.append(menuItem("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        items.append(menuItem("Заменить") { [weak self] in
            guard let self else { return }
            self.textView?.replaceMedia(ofBlock: self.block.id)
        })
        return items
    }

    // MARK: Ширина

    fileprivate func dragHandle(to point: NSPoint) {
        let center = bounds.midX
        liveWidthFraction = Self.clampedWidth(Double(2 * abs(point.x - center) / max(1, bounds.width)))
        needsLayout = true
    }

    fileprivate func endDrag() {
        guard let fraction = liveWidthFraction else { return }
        liveWidthFraction = nil
        textView?.setMediaWidth(fraction, ofBlock: block.id)
    }

    // MARK: Подпись

    private func beginCaption() {
        guard captionField == nil else {
            window?.makeFirstResponder(captionField)
            return
        }
        MediaCaptionEditing.blockId = block.id
        textView?.relayoutBlockView(block.id)
        showCaptionField(focus: true)
    }

    private func showCaptionField(focus: Bool) {
        let field = MediaCaptionField(text: block.text.string)
        field.onCommit = { [weak self] text in
            guard let self else { return }
            MediaCaptionEditing.blockId = nil
            if text != self.block.text.string {
                self.textView?.setMediaCaption(text, ofBlock: self.block.id)
            } else {
                self.textView?.relayoutBlockView(self.block.id)
            }
        }
        addSubview(field)
        captionField = field
        needsLayout = true
        if focus { DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(field) } }
    }
}

/// Ручка ширины: тянуть — ширина картинки симметрично от центра, как у Notion.
@MainActor
private final class ResizeHandle: NSView {
    weak var owner: ImageBlockView?

    init(owner: ImageBlockView) {
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = Metrics.Media.resizeHandleWidth / 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let owner else { return }
        owner.dragHandle(to: owner.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        owner?.endDrag()
    }
}

/// Блок, у которого сейчас правится пустая подпись: пока правится, строка подписи занимает место.
@MainActor
enum MediaCaptionEditing {
    static var blockId: UUID?
}

/// Свойства образцов для галереи и «богатой» страницы. Файлов за ними нет: галерея подставляет свои.
enum MediaSamples {
    static let downloadingName = "загружается.png"
    static let waitingName = "ждёт-отправки.png"
    /// Файл образца, который «копируется»: галерея показывает его заглушку с ходом копирования.
    static let copyingName = "Запись эфира.mov"

    static func image(name: String, width: Double?) -> BlockProps {
        var props = BlockProps()
        props.attachment = AttachmentRef(id: sampleId(name), name: name, byteCount: 1_200_000, contentType: "public.png",
                                         sha256: String(repeating: "0", count: 64))
        props.width = width
        props.pixelSize = PixelSize(width: 1600, height: 900)
        return props
    }

    static func file(name: String, byteCount: Int, contentType: String) -> BlockProps {
        var props = BlockProps()
        props.attachment = AttachmentRef(id: sampleId(name), name: name, byteCount: byteCount, contentType: contentType,
                                         sha256: String(repeating: "0", count: 64))
        return props
    }

    /// Постоянный id образца по имени: галерея узнаёт по нему, какой файл подставить.
    static func sampleId(_ name: String) -> UUID {
        var bytes = Array(name.utf8.reduce(into: [UInt8](repeating: 0, count: 16)) { acc, byte in
            for index in acc.indices { acc[index] = acc[index] &* 31 &+ byte &+ UInt8(index) }
        })
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9],
                           bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Действия с файлом копии: «Скачать копию…».
@MainActor
enum MediaFileActions {
    static func saveCopy(of url: URL, suggestedName: String? = nil) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName ?? url.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
