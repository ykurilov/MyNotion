import AppKit
import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    /// Закладка (US5, FR-109): карточка сайта — заголовок, описание, значок и адрес, справа картинка сайта.
    /// Данные — одним запросом при вставке; картинка и значок — вложениями, второй Mac сайт не запрашивает.
    static let bookmark = BlockKindDescriptor(
        kind: .bookmark,
        menuItem: PopupMenuItem(title: "Закладка", icon: .symbol("bookmark"), keywords: ["bookmark", "ссылка", "web", "закладка", "сайт"],
                                action: .setKind(.bookmark)),
        gallerySamples: [
            BlockGallerySample(id: "media-bookmark", summary: "Закладка с данными сайта и закладка без сети — только адрес",
                               blocks: [
                                   .init(.bookmark, props: MediaSamples.bookmark(full: true)),
                                   .init(.bookmark, props: MediaSamples.bookmark(full: false)),
                               ]),
        ],
        // Богатая страница (quickstart.md): 5 закладок.
        richPageBlocks: (1...5).map { number in RichBlockSpec(.bookmark, props: MediaSamples.bookmark(full: number.isMultiple(of: 2))) }
    )
}

extension MediaSamples {
    static func bookmark(full: Bool) -> BlockProps {
        var props = BlockProps()
        props.url = URL(string: full ? "https://www.notion.com/help/guides" : "https://example.com/article/2026/10/19")
        if full {
            props.title = "Руководства Notion — как устроены страницы и блоки"
            props.description = "Пошаговые руководства: страницы, блоки, базы данных и совместная работа. Всё, чтобы начать быстро."
            props.image = image(name: "обложка-сайта.png", width: nil).attachment
            props.iconAttachment = image(name: "значок-сайта.png", width: nil).attachment
        }
        return props
    }
}

/// Карточка закладки (contracts/blocks-and-keys.md, «Закладка»): щелчок открывает сайт, «⋯» — «Обновить», «Открыть».
@MainActor
final class BookmarkBlockView: MediaBlockView {
    private let card = MediaSurfaceView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let iconView = NSImageView()
    private let urlLabel = NSTextField(labelWithString: "")
    private let imageView = MediaSurfaceView()
    private var menuButton: MediaOverlayButton?

    private var imageURL: URL? { MediaBlocks.availability(of: block.props.image).fileURL }

    override init(block: Block, width: CGFloat) {
        super.init(block: block, width: width)
        setAccessibilityIdentifier("bookmark-block")
        card.borderColor = Palette.border
        addSubview(card)
        let props = block.props
        let address = props.url?.absoluteString ?? ""
        titleLabel.stringValue = props.title ?? ""
        titleLabel.font = .systemFont(ofSize: Metrics.Media.bookmarkTitleFontSize, weight: .medium)
        titleLabel.textColor = Palette.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.stringValue = props.description ?? ""
        descriptionLabel.font = .systemFont(ofSize: Metrics.Media.bookmarkDescriptionFontSize)
        descriptionLabel.textColor = Palette.textSecondary
        descriptionLabel.maximumNumberOfLines = 2
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.cell?.truncatesLastVisibleLine = true
        urlLabel.stringValue = address
        urlLabel.font = .systemFont(ofSize: Metrics.Media.bookmarkURLFontSize)
        urlLabel.textColor = Palette.textPrimary
        urlLabel.lineBreakMode = .byTruncatingTail
        iconView.imageScaling = .scaleProportionallyUpOrDown
        if let icon = MediaBlocks.availability(of: props.iconAttachment).fileURL { iconView.image = NSImage(contentsOf: icon) }
        imageView.cornerRadius = 0
        [titleLabel, descriptionLabel, iconView, urlLabel, imageView].forEach(card.addSubview)
        frame.size.height = Metrics.Media.bookmarkHeight + 2 * Metrics.Media.verticalPadding
        loadImage()
    }

    /// Заголовок, описание и адрес — для проверок и VoiceOver.
    var cardTexts: [String] { [titleLabel.stringValue, descriptionLabel.stringValue, urlLabel.stringValue].filter { !$0.isEmpty } }

    override func layout() {
        super.layout()
        let padding = Metrics.Media.bookmarkPadding
        card.frame = NSRect(x: 0, y: Metrics.Media.verticalPadding, width: bounds.width, height: Metrics.Media.bookmarkHeight)
        let hasImage = imageURL != nil
        let imageWidth = hasImage ? (card.bounds.width * Metrics.Media.bookmarkImageFraction).rounded() : 0
        imageView.frame = NSRect(x: card.bounds.width - imageWidth, y: 0, width: imageWidth, height: card.bounds.height)
        let textWidth = max(0, card.bounds.width - imageWidth - 2 * padding)
        // Без заголовка и описания — только адрес, по центру высоты.
        let hasText = !titleLabel.stringValue.isEmpty || !descriptionLabel.stringValue.isEmpty
        var y = padding
        titleLabel.frame = NSRect(x: padding, y: y, width: textWidth, height: 20)
        y += 20 + Metrics.Media.bookmarkLineSpacing
        descriptionLabel.preferredMaxLayoutWidth = textWidth
        descriptionLabel.frame = NSRect(x: padding, y: y, width: textWidth, height: 32)
        let urlY = hasText ? card.bounds.height - padding - Metrics.Media.bookmarkIconSize : (card.bounds.height - Metrics.Media.bookmarkIconSize) / 2
        let iconWidth = iconView.image == nil ? 0 : Metrics.Media.bookmarkIconSize + 6
        iconView.frame = NSRect(x: padding, y: urlY, width: Metrics.Media.bookmarkIconSize, height: Metrics.Media.bookmarkIconSize)
        urlLabel.frame = NSRect(x: padding + iconWidth, y: urlY, width: max(0, textWidth - iconWidth), height: Metrics.Media.bookmarkIconSize)
        menuButton?.frame.origin = NSPoint(x: bounds.width - Metrics.Media.menuButtonSize - Metrics.Media.menuButtonInset,
                                           y: Metrics.Media.verticalPadding + Metrics.Media.menuButtonInset)
    }

    override var isFlipped: Bool { true }

    private func loadImage() {
        guard let url = imageURL else { return }
        let pixels = Int(Metrics.Media.bookmarkHeight * 3 * (NSScreen.main?.backingScaleFactor ?? 2))
        Task { [weak self] in
            self?.imageView.image = await ImageThumbnailCache.shared.thumbnail(url, maxPixelSize: pixels)
        }
    }

    override func availabilityDidChange() {
        textView?.relayoutBlockView(block.id)
    }

    override func hoverDidChange() {
        card.fill = isHovered ? Palette.hoverBackground : nil
        if isHovered, menuButton == nil {
            let button = MediaOverlayButton(symbol: "ellipsis", size: Metrics.Media.menuButtonSize) { [weak self] in
                guard let self, let button = self.menuButton else { return }
                self.showMenu(from: button)
            }
            addSubview(button)
            menuButton = button
            needsLayout = true
        } else if !isHovered {
            menuButton?.removeFromSuperview()
            menuButton = nil
        }
    }

    /// Щелчок открывает сайт, как у Notion; выделить блок — «⋮⋮».
    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 1, let url = block.props.url else { return }
        MediaBlocks.services?.open(url)
    }

    override func mouseDown(with event: NSEvent) {}

    override func menuItems() -> [NSMenuItem] {
        guard let url = block.props.url else { return [] }
        return [
            menuItem("Обновить") { [weak self] in
                guard let self else { return }
                self.textView?.refreshBookmark(ofBlock: self.block.id)
            },
            menuItem("Открыть") { MediaBlocks.services?.open(url) },
        ]
    }
}
