import AppKit
import NotesCore

/// Виды блоков без своего текста на экране (research R2). TextKit 2 в `PageTextView` своих видов вложений не ставит
/// (проба US4 19.10.2026: место под абзацем есть, вида нет — и в приложении, и в пробе), поэтому страница ставит их сама:
/// после раскладки видимой области вид встаёт поверх своего абзаца, за её краем — снимается. Вид, в котором идёт
/// правка (код, подпись), не снимается, пока в нём курсор.
@MainActor
final class BlockViewHosting {
    weak var textView: PageTextView?
    /// Виды на странице по id блока.
    private(set) var views: [UUID: BlockAttachmentHostView] = [:]
    private var isUpdating = false
    /// Пока ставили виды, вид узнал свою высоту (колонки, таблица) и попросил поставить заново.
    private var needsAnotherPass = false
    /// Прокрутка без расстановки видов: место прокрутки вкладки ставится до раскладки, виды встанут после неё.
    private var ignoresScrolling = false

    init(textView: PageTextView) {
        self.textView = textView
    }

    /// Вид блока, если он сейчас на странице.
    func view(for blockId: UUID) -> BlockAttachmentHostView? { views[blockId] }

    /// Поставить виды абзацам-вложениям видимой области (с запасом в экран сверху и снизу), снять остальные.
    func update() {
        guard !isUpdating else {
            needsAnotherPass = true
            return
        }
        // Вид, поставленный впервые, узнаёт свою высоту и перекладывает абзац: ещё проход ставит его по новой высоте.
        for _ in 0..<3 {
            needsAnotherPass = false
            isUpdating = true
            place()
            isUpdating = false
            if !needsAnotherPass { break }
        }
    }

    private func place() {
        guard let textView, let layoutManager = textView.textLayoutManager, let storage = textView.textContentStorage,
              let textStorage = textView.textStorage else { return }
        let visible = textView.visibleRect
        let area = visible.insetBy(dx: 0, dy: -visible.height)
        let origin = textView.textContainerOrigin
        var wanted: [UUID: (BlockAttachment, NSRect, columnWidth: CGFloat)] = [:]
        // Страница без блоков-вложений: искать нечего (прокрутка страницы на 10 000 блоков — без лишнего прохода).
        let hasAttachments = !views.isEmpty || textView.document.blocks.contains { $0.kind.rendersAsAttachment }
        // Начало поиска — разложенный абзац у верха области. Его нет — прокрутка ушла туда, где TextKit ещё не раскладывал:
        // раскладка от начала страницы стоила бы сотни миллисекунд, поэтому ждём её раскладки (`layout()` позовёт снова).
        // Раскладывать с начала можно только у начала страницы — при открытии.
        func laidOut(atY y: CGFloat) -> NSTextLocation? {
            layoutManager.textLayoutFragment(for: NSPoint(x: 0, y: max(0, y - origin.y)))?.rangeInElement.location
        }
        let nearTop = visible.minY - origin.y < visible.height * 2
        if hasAttachments, !visible.isEmpty,
           let start = laidOut(atY: area.minY) ?? laidOut(atY: visible.minY) ?? (nearTop ? storage.documentRange.location : nil) {
            layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
                let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
                guard frame.minY <= area.maxY else { return false }
                let offset = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
                guard offset < textStorage.length,
                      let attachment = textStorage.attribute(.attachment, at: offset, effectiveRange: nil) as? BlockAttachment,
                      let line = fragment.textLineFragments.first else { return true }
                // Вид — по месту знака-вложения в строке: левее — отступ вложенности, сверху — отступ абзаца.
                let lineBounds = line.typographicBounds
                let glyphX = line.locationForCharacter(at: 0).x
                let x = frame.minX + lineBounds.minX + glyphX
                let width = max(0, origin.x + (textView.textContainer?.size.width ?? frame.width) - x
                                - (textView.textContainer?.lineFragmentPadding ?? 0))
                let height = attachment.height(forWidth: width, in: textView)
                let viewWidth = Self.viewWidth(of: attachment, columnWidth: width, maxWidth: max(width, textView.bounds.maxX - x), in: textView)
                let rect = NSRect(x: x, y: frame.minY + lineBounds.minY, width: viewWidth, height: height)
                if rect.intersects(area) { wanted[attachment.blockId] = (attachment, rect.integral, width) }
                return true
            }
        }
        for (id, view) in views where wanted[id] == nil && !view.isEditing {
            view.removeFromSuperview()
            views[id] = nil
        }
        for (id, (attachment, rect, columnWidth)) in wanted {
            if let view = views[id] {
                view.columnWidth = columnWidth
                if view.frame != rect { view.frame = rect }
                view.update(attachment.block)
            } else {
                let view = BlockAttachmentViewProvider.makeHostedView(for: attachment, textView: textView)
                view.columnWidth = columnWidth
                view.frame = rect
                textView.addSubview(view)
                views[id] = view
            }
        }
    }

    /// Ширина вида блока по его фабрике: широкая таблица занимает место справа до края страницы.
    private static func viewWidth(of attachment: BlockAttachment, columnWidth: CGFloat, maxWidth: CGFloat, in textView: PageTextView) -> CGFloat {
        BlockViewFactories.shared.factory(for: attachment.block.kind)?
            .viewWidth(for: attachment.block, columnWidth: columnWidth, maxWidth: maxWidth,
                       context: BlockViewContext(textView: textView, width: columnWidth)) ?? columnWidth
    }

    /// Прокрутить, не ставя виды на абзацы, которые ещё не разложены на новом месте.
    func withoutUpdatesOnScroll(_ scroll: () -> Void) {
        ignoresScrolling = true
        defer { ignoresScrolling = false }
        scroll()
    }

    /// Снять все виды (страница загружена заново).
    func removeAll() {
        for view in views.values { view.removeFromSuperview() }
        views = [:]
    }

    /// Подписка снимается в `deinit` — он не привязан к главному потоку.
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    /// Прокрутка страницы: виды встают на новые видимые абзацы.
    func observeScrolling() {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        guard let clip = textView?.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { if self?.ignoresScrolling == false { self?.update() } }
        }
    }
}

/// Вид блока, которому нужно знать новые поля блока, когда он остаётся на экране (код, формула, оглавление).
@MainActor
protocol BlockFieldsView: AnyObject {
    func update(_ block: Block)
}

extension BlockAttachmentHostView {
    /// В виде курсор (первый ответчик — он сам или вид внутри): за краем видимой области он не снимается.
    var isEditing: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    func update(_ block: Block) {
        for case let view as BlockFieldsView in subviews { view.update(block) }
    }
}
