import AppKit
import NotesCore
import SwiftUI
import VisualStyle

/// Просмотр версии в окне истории: редактор «только чтение» в прокрутке под прозрачным щитом — мышь только прокручивает.
/// На каждую версию — свой вид: задавайте `.id(versionId)`.
public struct VersionPreviewView: NSViewRepresentable {
    let document: PageDocument
    let highlightedBlockIds: Set<UUID>
    let linkedPages: [UUID: LinkedPage]
    let mentions: MentionSettings
    let headerAddons: [PageHeaderAddonFactory]

    public init(document: PageDocument, highlightedBlockIds: Set<UUID>, linkedPages: [UUID: LinkedPage] = [:],
                mentions: MentionSettings = MentionSettings(), headerAddons: [PageHeaderAddonFactory] = []) {
        self.document = document
        self.highlightedBlockIds = highlightedBlockIds
        self.linkedPages = linkedPages
        self.mentions = mentions
        self.headerAddons = headerAddons
    }

    public func makeNSView(context: Context) -> VersionPreviewContainer {
        let textView = VersionPreviewTextView(document: document, initialFocus: .unchanged)
        textView.isEditable = false
        textView.highlightedBlockIds = highlightedBlockIds
        textView.linkedPages = linkedPages
        mentions.apply(to: textView)
        let scrollView = PageTextEditor.makeScrollView(around: textView)
        textView.installHeaderAddons(headerAddons.map { $0(document) })
        textView.showAppearance(of: document.page)
        return VersionPreviewContainer(scrollView: scrollView, textView: textView)
    }

    public func updateNSView(_ container: VersionPreviewContainer, context: Context) {
        container.textView.highlightedBlockIds = highlightedBlockIds
    }

    public static func dismantleNSView(_ container: VersionPreviewContainer, coordinator: ()) {
        PageTextEditor.detachSubviews(of: container.textView)
    }
}

/// Прокрутка версии и щит над ней: щелчки и наведение не доходят до редактора (ни ручек «⋮⋮», ни чекбоксов),
/// колесо прокручивает.
@MainActor
public final class VersionPreviewContainer: NSView {
    public let scrollView: NSScrollView
    public let textView: VersionPreviewTextView
    private let shield = ScrollOnlyShield()

    init(scrollView: NSScrollView, textView: VersionPreviewTextView) {
        self.scrollView = scrollView
        self.textView = textView
        super.init(frame: .zero)
        scrollView.autoresizingMask = [.width, .height]
        shield.autoresizingMask = [.width, .height]
        shield.scrollView = scrollView
        addSubview(scrollView)
        addSubview(shield)
        setAccessibilityIdentifier("version-preview")
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    @objc private func scrolled() { textView.stripHoverTracking() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        shield.frame = bounds
        textView.stripHoverTracking()
    }
}

private final class ScrollOnlyShield: NSView {
    weak var scrollView: NSScrollView?

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) { scrollView?.scrollWheel(with: event) }
    override func isAccessibilityElement() -> Bool { false }
}
