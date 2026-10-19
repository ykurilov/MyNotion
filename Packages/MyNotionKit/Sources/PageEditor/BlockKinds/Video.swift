import AppKit
import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    /// Видео (US5, FR-108): файл — первый кадр и ▶, YouTube и Vimeo — обложка, название и ▶. Проигрыватель создаётся
    /// только по нажатию и закрывается, когда блок уходит с экрана (research R8).
    static let video = BlockKindDescriptor(
        kind: .video,
        menuItem: PopupMenuItem(title: "Видео", icon: .symbol("play.rectangle"), keywords: ["video", "youtube", "vimeo", "видео", "ролик"],
                                action: .setKind(.video)),
        gallerySamples: [
            BlockGallerySample(id: "media-video", summary: "Видео YouTube с обложкой и названием, видеофайл с подписью",
                               blocks: [
                                   .init(.video, props: MediaSamples.youtube),
                                   .init(.video, "Подпись видео", props: MediaSamples.videoFile),
                               ]),
        ],
        // Богатая страница (quickstart.md): 2 видео — файл и YouTube.
        richPageBlocks: [RichBlockSpec(.video, "Видеофайл", props: MediaSamples.videoFile), RichBlockSpec(.video, props: MediaSamples.youtube)]
    )
}

extension MediaSamples {
    static var youtube: BlockProps {
        var props = BlockProps()
        props.videoSource = .youtube
        props.url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        props.title = "Видео YouTube"
        props.poster = image(name: "обложка-youtube.jpg", width: nil).attachment
        return props
    }

    static var videoFile: BlockProps {
        var props = file(name: "ролик.mov", byteCount: 24_000_000, contentType: "com.apple.quicktime-movie")
        props.videoSource = .file
        return props
    }
}

/// Блоки, для которых обложку уже запрашивали в этом запуске.
@MainActor
enum MediaCoverRequests {
    static var attempted: Set<UUID> = []
}

/// Вид видео: кадр или обложка во всю ширину (16 : 9), ▶ по центру; нажатие — проигрыватель на месте кадра.
/// Блок ушёл с экрана — вид отпускается вместе с проигрывателем.
@MainActor
final class VideoBlockView: MediaBlockView {
    private let coverView = MediaSurfaceView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private var playButton: MediaOverlayButton?
    private var captionField: MediaCaptionField?
    private(set) var player: NSView?

    private var isWebVideo: Bool { block.props.videoSource == .youtube || block.props.videoSource == .vimeo }

    /// Файл видео на этом Mac (у роликов сайтов — обложка).
    private var fileAvailability: MediaAvailability { MediaBlocks.availability(of: block.props.attachment) }

    override init(block: Block, width: CGFloat) {
        super.init(block: block, width: width)
        setAccessibilityIdentifier("video-block")
        coverView.fill = NSColor.black.withAlphaComponent(0.85)
        addSubview(coverView)
        for label in [statusLabel, titleLabel] {
            label.textColor = .white
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        titleLabel.font = .systemFont(ofSize: Metrics.Media.captionFontSize, weight: .medium)
        titleLabel.stringValue = isWebVideo ? (block.props.title ?? block.props.url?.absoluteString ?? "") : ""
        statusLabel.font = .systemFont(ofSize: Metrics.Media.captionFontSize)
        statusLabel.alignment = .center
        if !isWebVideo, fileAvailability.fileURL == nil {
            statusLabel.stringValue = "\(block.props.attachment?.name ?? "Видео") — \(fileAvailability.statusText)"
        }
        if isWebVideo || fileAvailability.fileURL != nil {
            let button = MediaOverlayButton(symbol: "play.fill", size: Metrics.Media.playButtonSize) { [weak self] in self?.play() }
            button.setAccessibilityLabel("Играть")
            button.setAccessibilityIdentifier("video-play")
            addSubview(button)
            playButton = button
        }
        if !block.text.string.isEmpty || MediaCaptionEditing.blockId == block.id { showCaptionField(focus: false) }
        frame.size.height = Self.contentHeight(for: block, width: width) + 2 * Metrics.Media.verticalPadding
        loadCover()
    }

    static func videoSize(for block: Block, width: CGFloat) -> NSSize {
        let videoWidth = (width * ImageBlockView.clampedWidth(block.props.width ?? 1)).rounded()
        return NSSize(width: videoWidth, height: (videoWidth * Metrics.Media.defaultAspectRatio).rounded())
    }

    static func contentHeight(for block: Block, width: CGFloat) -> CGFloat {
        let caption = !block.text.string.isEmpty || MediaCaptionEditing.blockId == block.id
        return videoSize(for: block, width: width).height + (caption ? Metrics.Media.captionHeight : 0)
    }

    override func layout() {
        super.layout()
        let size = Self.videoSize(for: block, width: bounds.width)
        let frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: Metrics.Media.verticalPadding, width: size.width, height: size.height)
        coverView.frame = frame
        player?.frame = frame
        statusLabel.frame = NSRect(x: frame.minX + 12, y: frame.midY + Metrics.Media.playButtonSize / 2 + 8, width: max(0, frame.width - 24), height: 20)
        titleLabel.frame = NSRect(x: frame.minX + 14, y: frame.minY + 12, width: max(0, frame.width - 28), height: 20)
        playButton?.frame.origin = NSPoint(x: frame.midX - Metrics.Media.playButtonSize / 2, y: frame.midY - Metrics.Media.playButtonSize / 2)
        captionField?.frame = NSRect(x: frame.minX, y: frame.maxY + Metrics.Media.captionSpacing, width: frame.width,
                                     height: Metrics.Media.captionLineHeight)
    }

    // MARK: Обложка

    private func loadCover() {
        let services = MediaBlocks.services
        if isWebVideo {
            guard let url = MediaBlocks.availability(of: block.props.poster).fileURL else {
                let id = block.id
                if block.props.poster == nil, let address = block.props.url, MediaCoverRequests.attempted.insert(id).inserted {
                    // Ролик из импорта: обложка запрашивается в фоне один раз за запуск, без сети — карточка с адресом.
                    Task { [weak self] in
                        guard let cover = await services?.videoCover(for: address) else { return }
                        self?.textView?.applyFetchedPreview(cover, toBlock: id)
                    }
                }
                return
            }
            let pixels = Int(Self.videoSize(for: block, width: bounds.width).width * (NSScreen.main?.backingScaleFactor ?? 2))
            Task { [weak self] in
                self?.coverView.image = await ImageThumbnailCache.shared.thumbnail(url, maxPixelSize: pixels)
            }
        } else if let url = fileAvailability.fileURL {
            Task { [weak self] in
                guard let image = await services?.posterImage(forVideoAt: url) else { return }
                self?.coverView.image = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        }
    }

    /// Файл пришёл или сменил состояние: вид заново на том же месте, высота строки та же.
    override func availabilityDidChange() {
        rebuild()
    }

    // MARK: Проигрыватель

    /// ▶: проигрыватель на месте кадра. Второе видео в окне закрывает первое (`EmbeddedMedia`).
    func play() {
        guard player == nil, let services = MediaBlocks.services,
              let view = services.makePlayer(for: block, fileURL: fileAvailability.fileURL) else { return }
        playButton?.isHidden = true
        titleLabel.isHidden = true
        view.frame = coverView.frame
        addSubview(view)
        player = view
    }

    override func menuItems() -> [NSMenuItem] {
        var items = [menuItem("Подпись") { [weak self] in self?.beginCaption() }]
        if let url = block.props.url, isWebVideo {
            items.append(menuItem("Открыть на сайте") { MediaBlocks.openLink(url) })
        } else if let url = fileAvailability.fileURL {
            items.append(menuItem("Скачать") { MediaFileActions.saveCopy(of: url) })
            items.append(menuItem("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        return items
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
