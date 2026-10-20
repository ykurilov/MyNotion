import AppKit
import XCTest

/// Проба видов-вложений (T005, research R2): 50 абзацев из одного знака-вложения с `NSTextAttachmentViewProvider`
/// (вид 720 × 300) среди 1 000 абзацев в `NSTextView` на TextKit 2. Прокрутка — p95 ≤ 50 мс; живых видов — не больше
/// видимых плюс запас раскладки; смена высоты одного вида перекладывает только его абзац.
@MainActor
final class AttachmentViewsProbeTests: XCTestCase {
    static let paragraphCount = 1_000
    static let attachmentEvery = 20

    func testAttachmentViewsScrollAndLifetime() async throws {
        _ = NSApplication.shared
        ProbeAttachmentView.live = 0
        ProbeAttachmentView.created = 0
        let probe = AttachmentProbePage()
        defer { probe.window.orderOut(nil) }
        probe.window.displayIfNeeded()

        var samples: [Double] = []
        var maxLive = 0
        var maxExcess = 0
        var direction: CGFloat = 1
        let clip = probe.scrollView.contentView
        for _ in 0..<120 {
            let maxY = max(0, probe.textView.frame.height - clip.bounds.height)
            var y = clip.bounds.origin.y + direction * clip.bounds.height
            if y > maxY || y < 0 {
                direction = -direction
                y = min(max(0, clip.bounds.origin.y + direction * clip.bounds.height), maxY)
            }
            samples.append(ProbeEditor.measure {
                clip.scroll(to: NSPoint(x: 0, y: y))
                probe.scrollView.reflectScrolledClipView(clip)
                probe.window.displayIfNeeded()
            })
            let live = ProbeAttachmentView.liveInHierarchy(of: probe.textView)
            maxLive = max(maxLive, live)
            maxExcess = max(maxExcess, live - probe.visibleAttachmentCount())
            try await Task.sleep(for: .milliseconds(10))
        }

        // Смена высоты одного видимого вида.
        let target = try XCTUnwrap(probe.firstVisibleAttachmentIndex(), "На экране нет вложения")
        let belowBefore = probe.fragmentFrame(ofParagraph: target + 1)
        let ownBefore = probe.fragmentFrame(ofParagraph: target)
        var relaidOut = 0
        let resizeMs = ProbeEditor.measure {
            relaidOut = probe.resizeAttachment(atParagraph: target, toHeight: 500)
            probe.window.displayIfNeeded()
        }
        let belowAfter = probe.fragmentFrame(ofParagraph: target + 1)
        let ownAfter = probe.fragmentFrame(ofParagraph: target)

        let summary = """
            Прокрутка 1 000 абзацев с 50 видами-вложениями: p95 \(ProbeEditor.format(ProbeEditor.p95(samples))) мс, \
            худший \(ProbeEditor.format(samples.max() ?? 0)) мс
            Проба: видов создано \(ProbeAttachmentView.created), живых в окне не больше \(maxLive), сверх видимых не больше \(maxExcess)
            Проба: смена высоты вида 300 → 500 — \(ProbeEditor.format(resizeMs)) мс, переложено абзацев \(relaidOut), \
            свой абзац \(Int(ownBefore.height)) → \(Int(ownAfter.height)), ниже сдвинут на \(Int(belowAfter.minY - belowBefore.minY))
            """
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertLessThanOrEqual(ProbeEditor.p95(samples), 50, "Прокрутка с видами: p95 больше 50 мс")
        XCTAssertLessThan(maxLive, 50, "Живут виды всех вложений, а не только видимых")
        XCTAssertLessThanOrEqual(maxExcess, 6, "Видов сверх видимых больше запаса раскладки")
        XCTAssertEqual(ownAfter.height - ownBefore.height, 200, accuracy: 1, "Высота абзаца вида не поменялась")
        XCTAssertEqual(belowAfter.minY - belowBefore.minY, 200, accuracy: 1, "Абзац ниже не сдвинулся")
        XCTAssertLessThanOrEqual(relaidOut, 3, "Смена высоты переложила больше своего абзаца")
    }
}

/// Страница проб: текст TextKit 2 с колонкой как у страницы MyNotion.
@MainActor
final class AttachmentProbePage {
    let window: NSWindow
    let scrollView: NSScrollView
    let textView: NSTextView
    let counter = LayoutCounter()
    private(set) var attachments: [Int: ProbeAttachment] = [:]

    init() {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 720, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layoutManager.textContainer = container
        layoutManager.delegate = counter
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 1200, height: 0), textContainer: container)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 240, height: 40)

        let text = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 16)
        for index in 0..<AttachmentViewsProbeTests.paragraphCount {
            if index % AttachmentViewsProbeTests.attachmentEvery == 5 {
                let attachment = ProbeAttachment()
                attachments[index] = attachment
                text.append(NSAttributedString(attachment: attachment))
                text.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            } else {
                text.append(NSAttributedString(string: "Абзац \(index): обычный текст страницы, mixed with Latin words.\n",
                                               attributes: [.font: font]))
            }
        }
        textView.textStorage?.setAttributedString(text)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        scrollView = NSScrollView(frame: window.contentLayoutRect)
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
    }

    func paragraphRange(_ index: Int) -> NSTextRange? {
        guard let storage = textView.textContentStorage else { return nil }
        let string = textView.string as NSString
        var location = 0
        for _ in 0..<index { location = NSMaxRange(string.paragraphRange(for: NSRange(location: location, length: 0))) }
        let length = string.paragraphRange(for: NSRange(location: location, length: 0)).length
        guard let start = storage.location(storage.documentRange.location, offsetBy: location),
              let end = storage.location(start, offsetBy: length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    func fragmentFrame(ofParagraph index: Int) -> CGRect {
        guard let range = paragraphRange(index), let layoutManager = textView.textLayoutManager else { return .null }
        layoutManager.ensureLayout(for: range)
        return layoutManager.textLayoutFragment(for: range.location)?.layoutFragmentFrame ?? .null
    }

    /// Вложения, чей абзац сейчас в видимой области.
    func visibleAttachmentCount() -> Int {
        attachmentIndicesOnScreen().count
    }

    func firstVisibleAttachmentIndex() -> Int? {
        attachmentIndicesOnScreen().first
    }

    private func attachmentIndicesOnScreen() -> [Int] {
        let visible = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
        return attachments.keys.sorted().filter { fragmentFrame(ofParagraph: $0).intersects(visible) }
    }

    /// Поменять высоту вида и переложить только его абзац. Возвращает, сколько абзацев переложено.
    func resizeAttachment(atParagraph index: Int, toHeight height: CGFloat) -> Int {
        guard let attachment = attachments[index], let range = paragraphRange(index), let layoutManager = textView.textLayoutManager
        else { return -1 }
        attachment.height = height
        counter.count = 0
        layoutManager.invalidateLayout(for: range)
        layoutManager.textViewportLayoutController.layoutViewport()
        return counter.count
    }
}

/// Считает созданные фрагменты раскладки: столько абзацев переложено.
final class LayoutCounter: NSObject, NSTextLayoutManagerDelegate {
    nonisolated(unsafe) var count = 0

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        count += 1
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

final class ProbeAttachment: NSTextAttachment, @unchecked Sendable {
    var height: CGFloat = 300

    override func viewProvider(for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = ProbeViewProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager,
                                         location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        CGRect(x: 0, y: 0, width: 720, height: height)
    }
}

final class ProbeViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        nonisolated(unsafe) let provider = self
        MainActor.assumeIsolated { provider.view = ProbeAttachmentView(frame: NSRect(x: 0, y: 0, width: 720, height: 300)) }
    }
}

final class ProbeAttachmentView: NSView {
    nonisolated(unsafe) static var live = 0
    nonisolated(unsafe) static var created = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        Self.live += 1
        Self.created += 1
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.3).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { Self.live -= 1 }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)).stroke()
    }

    /// Виды-вложения, стоящие сейчас в окне текста.
    static func liveInHierarchy(of view: NSView) -> Int {
        func count(_ view: NSView) -> Int { (view is ProbeAttachmentView ? 1 : 0) + view.subviews.map(count).reduce(0, +) }
        return count(view)
    }
}
