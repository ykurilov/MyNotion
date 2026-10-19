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
        card.cornerRadius = Metrics.Media.bookmarkCornerRadius
        addSubview(card)
        let props = block.props
        let address = props.url?.absoluteString ?? ""
        titleLabel.stringValue = props.title ?? ""
        titleLabel.font = .systemFont(ofSize: Metrics.Media.bookmarkTitleFontSize)
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
        urlLabel.textColor = Palette.textSecondary
        urlLabel.lineBreakMode = .byTruncatingTail
        iconView.imageScaling = .scaleProportionallyUpOrDown
        if let icon = MediaBlocks.availability(of: props.iconAttachment).fileURL { iconView.image = NSImage(contentsOf: icon) }
        imageView.cornerRadius = Metrics.Media.bookmarkCornerRadius
        imageView.roundsLeadingCornersOnly = true
        [titleLabel, descriptionLabel, iconView, urlLabel, imageView].forEach(card.addSubview)
        frame.size.height = Self.contentHeight(for: block) + 2 * Metrics.Media.verticalPadding
        loadImage()
    }

    /// Заголовок, описание и адрес — для проверок и VoiceOver.
    var cardTexts: [String] { [titleLabel.stringValue, descriptionLabel.stringValue, urlLabel.stringValue].filter { !$0.isEmpty } }

    /// С данными сайта — высокая карточка, без них — низкая с одним адресом.
    static func contentHeight(for block: Block) -> CGFloat {
        let props = block.props
        let hasData = props.title != nil || props.description != nil || props.image != nil
        return hasData ? Metrics.Media.bookmarkHeight : Metrics.Media.bookmarkCompactHeight
    }

    override func layout() {
        super.layout()
        let padding = Metrics.Media.bookmarkPadding
        card.frame = NSRect(x: 0, y: Metrics.Media.verticalPadding, width: bounds.width, height: Self.contentHeight(for: block))
        let imageWidth = imageURL != nil ? (card.bounds.width * Metrics.Media.bookmarkImageFraction).rounded() : 0
        imageView.frame = NSRect(x: 0, y: 0, width: imageWidth, height: card.bounds.height)
        let left = imageWidth > 0 ? imageWidth + Metrics.Media.bookmarkTextLeading : padding
        let textWidth = max(0, card.bounds.width - left - padding)
        var y = padding
        if iconView.image != nil {
            iconView.frame = NSRect(x: left, y: y, width: Metrics.Media.bookmarkIconSize, height: Metrics.Media.bookmarkIconSize)
            y += Metrics.Media.bookmarkIconSize + Metrics.Media.bookmarkLineSpacing
        } else {
            iconView.frame = .zero
        }
        titleLabel.frame = NSRect(x: left, y: y, width: textWidth, height: Metrics.Media.bookmarkTitleLineHeight)
        y += Metrics.Media.bookmarkTitleLineHeight + 2
        descriptionLabel.preferredMaxLayoutWidth = textWidth
        descriptionLabel.frame = NSRect(x: left, y: y, width: textWidth, height: 2 * Metrics.Media.bookmarkDescriptionLineHeight)
        let urlHeight: CGFloat = 16
        let urlY = card.bounds.height == Metrics.Media.bookmarkCompactHeight
            ? (card.bounds.height - urlHeight) / 2 : card.bounds.height - padding - urlHeight
        urlLabel.frame = NSRect(x: left, y: urlY, width: textWidth, height: urlHeight)
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

    /// Файл пришёл или сменил состояние: вид заново на том же месте, высота строки та же.
    override func availabilityDidChange() {
        rebuild()
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
