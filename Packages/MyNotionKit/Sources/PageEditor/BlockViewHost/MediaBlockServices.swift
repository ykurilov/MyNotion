import AppKit
import NotesCore
import VisualStyle

/// Что редактору нужно от вложений, сети и проигрывателей для картинки, файла, видео и закладки (plan.md, Structure
/// Decision): копии файлов (`Attachments`), карточки и обложки (`LinkPreview`), проигрыватели (`EmbeddedMedia`).
/// Реализует приложение; редактор этих модулей не знает.
@MainActor
public protocol MediaBlockServices: AnyObject {
    /// Есть ли файл на этом Mac, а если нет — что показать на заглушке.
    func availability(of ref: AttachmentRef) -> MediaAvailability
    /// Занять место под файл (Finder, «Выбрать файл…») до копирования: блок с этим описанием появляется сразу;
    /// больше 100 МБ — ошибка с понятным сообщением.
    func reserveFileImport(at url: URL) throws -> AttachmentRef
    /// Скопировать файл под занятым описанием; `progress` — доля скопированного. Готовое описание — с SHA-256.
    func importFile(at url: URL, into reserved: AttachmentRef, progress: @escaping @Sendable (Double) -> Void) async throws -> AttachmentRef
    /// Записать содержимое буфера как файл (картинка — PNG).
    func importData(_ data: Data, name: String, contentType: String) async throws -> AttachmentRef
    /// Скачать файл по ссылке («Вставить ссылку» для картинки и файла).
    func downloadFile(from url: URL) async throws -> AttachmentRef
    /// YouTube или Vimeo; `nil` — не видео.
    func videoSource(for url: URL) -> VideoSource?
    /// Данные карточки закладки: один запрос; картинка и значок — уже вложениями. Без сети — пусто.
    func linkPreview(for url: URL) async -> MediaLinkPreview
    /// Название и обложка ролика YouTube или Vimeo; `nil` — без сети.
    func videoCover(for url: URL) async -> MediaLinkPreview?
    /// Первый кадр видеофайла.
    func posterImage(forVideoAt url: URL) async -> NSImage?
    /// Проигрыватель блока видео, уже играющий: файл — проигрыватель macOS, YouTube и Vimeo — проигрыватель сайта.
    func makePlayer(for block: Block, fileURL: URL?) -> NSView?
    /// Открыть адрес в браузере.
    func open(_ url: URL)
}

/// Что вид блока показывает вместо файла (contracts/blocks-and-keys.md, «Картинка»).
public enum MediaAvailability: Sendable, Hashable {
    case ready(URL)
    /// Файл копируется в MyNotion: доля скопированного, от 0 до 1.
    case copying(Double)
    case downloading
    case waitingForOtherMac
    case failed(String)

    var fileURL: URL? {
        if case .ready(let url) = self { url } else { nil }
    }

    /// Надпись на заглушке.
    var statusText: String {
        switch self {
        case .ready: ""
        case .copying(let fraction): "Копируется… \(Int((fraction * 100).rounded(.down))) %"
        case .downloading: "Загружается…"
        case .waitingForOtherMac: "Ждёт отправки с другого Mac"
        case .failed(let message): message
        }
    }
}

/// Данные карточки закладки или обложки ролика.
public struct MediaLinkPreview: Sendable, Hashable {
    public var title: String?
    public var description: String?
    public var image: AttachmentRef?
    public var icon: AttachmentRef?

    public init(title: String?, description: String?, image: AttachmentRef?, icon: AttachmentRef?) {
        self.title = title
        self.description = description
        self.image = image
        self.icon = icon
    }
}

/// Службы медиа-блоков и их виды: приложение ставит службы при запуске, виды картинки, файла, видео и закладки
/// регистрируются в `BlockViewFactories`.
@MainActor
public enum MediaBlocks {
    private(set) static var services: (any MediaBlockServices)?

    public static func install(_ services: any MediaBlockServices) {
        self.services = services
        BlockViewFactories.shared.register(MediaBlockViewFactory(kind: .image), for: .image)
        BlockViewFactories.shared.register(MediaBlockViewFactory(kind: .file), for: .file)
        BlockViewFactories.shared.register(MediaBlockViewFactory(kind: .video), for: .video)
        BlockViewFactories.shared.register(MediaBlockViewFactory(kind: .bookmark), for: .bookmark)
    }

    static func availability(of ref: AttachmentRef?) -> MediaAvailability {
        guard let ref else { return .failed("Файл не выбран") }
        if let fraction = copyProgress[ref.id] { return .copying(fraction) }
        return services?.availability(of: ref) ?? .downloading
    }

    /// Файлы, которые сейчас копируются, и доля скопированного.
    private static var copyProgress: [UUID: Double] = [:]

    /// Начать показ хода копирования файла `id`.
    static func beginCopy(_ id: UUID) {
        copyProgress[id] = 0
        NotificationCenter.default.post(name: AttachmentRef.availabilityDidChange, object: id)
    }

    /// Новая доля скопированного; виды перерисовываются, когда меняется целый процент. Поздние доли после конца — мимо.
    static func setCopyProgress(_ fraction: Double, of id: UUID) {
        guard let old = copyProgress[id], Int(old * 100) != Int(fraction * 100) else { return }
        copyProgress[id] = fraction
        NotificationCenter.default.post(name: AttachmentRef.availabilityDidChange, object: id)
    }

    /// Копирование кончилось (или не вышло): дальше вид спрашивает службы.
    static func endCopy(_ id: UUID) {
        copyProgress[id] = nil
        NotificationCenter.default.post(name: AttachmentRef.availabilityDidChange, object: id)
    }
}

/// Фабрика видов медиа-блоков: высота строки и вид по типу.
@MainActor
final class MediaBlockViewFactory: BlockViewFactory {
    let kind: BlockKind

    init(kind: BlockKind) {
        self.kind = kind
    }

    func makeView(for block: Block, context: BlockViewContext) -> NSView? {
        let view: MediaBlockView = switch kind {
        case .image: ImageBlockView(block: block, width: context.width)
        case .file: FileBlockView(block: block, width: context.width)
        case .video: VideoBlockView(block: block, width: context.width)
        default: BookmarkBlockView(block: block, width: context.width)
        }
        view.textView = context.textView
        return view
    }

    func height(for block: Block, width: CGFloat) -> CGFloat? {
        let padding = 2 * Metrics.Media.verticalPadding
        switch kind {
        case .image: return ImageBlockView.contentHeight(for: block, width: width) + padding
        case .video: return VideoBlockView.contentHeight(for: block, width: width) + padding
        case .file: return Metrics.Media.fileRowHeight + padding
        default: return BookmarkBlockView.contentHeight(for: block) + padding
        }
    }
}

/// Общее у видов медиа-блоков: блок, правки через страницу, меню «⋯», перерисовка при приходе файла.
@MainActor
class MediaBlockView: NSView {
    let block: Block
    weak var textView: PageTextView?
    private var availabilityObserver: NSObjectProtocol?
    private var trackingArea: NSTrackingArea?
    private(set) var isHovered = false

    init(block: Block, width: CGFloat) {
        self.block = block
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        let ids = Set(block.props.attachmentRefs.map(\.id))
        if !ids.isEmpty {
            availabilityObserver = NotificationCenter.default.addObserver(forName: AttachmentRef.availabilityDidChange, object: nil,
                                                                          queue: .main) { [weak self] note in
                guard let id = note.object as? UUID, ids.contains(id) else { return }
                MainActor.assumeIsolated { self?.availabilityDidChange() }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    isolated deinit {
        if let availabilityObserver { NotificationCenter.default.removeObserver(availabilityObserver) }
    }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Файл появился на этом Mac или сменил состояние.
    func availabilityDidChange() {}

    /// Пункты меню «⋯» и правого щелчка.
    func menuItems() -> [NSMenuItem] { [] }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        hoverDidChange()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hoverDidChange()
    }

    func hoverDidChange() {}

    override func menu(for event: NSEvent) -> NSMenu? {
        let items = menuItems()
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        items.forEach(menu.addItem)
        return menu
    }

    /// Пункт меню, который выполняет `action`.
    func menuItem(_ title: String, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.perform(_:)), keyEquivalent: "")
        let target = MenuAction(action)
        item.target = target
        item.representedObject = target
        return item
    }

    /// Кнопка «⋯»: то же меню, что правым щелчком.
    func showMenu(from button: NSView) {
        let menu = NSMenu()
        menuItems().forEach(menu.addItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 2), in: button)
    }

    /// Щелчок по виду, а не по его кнопкам — выделить блок, как щелчок по «⋮⋮».
    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }
}

/// Страница переиспользует вид блока, пока он на экране (`BlockViewHosting`): новые поля блока или пришедший файл —
/// вид создаётся заново на том же месте (медиа-вид берёт поля один раз, при создании).
extension MediaBlockView: BlockFieldsView {
    func update(_ block: Block) {
        guard block != self.block else { return }
        rebuild(with: block)
    }

    /// Вид заново с теми же размерами внутри той же рамки.
    func rebuild(with block: Block? = nil) {
        guard let host = superview else { return }
        let block = block ?? self.block
        let fresh = MediaBlockViewFactory(kind: block.kind).makeView(for: block, context: BlockViewContext(textView: textView, width: host.bounds.width))
        guard let fresh else { return }
        fresh.frame = frame
        fresh.autoresizingMask = autoresizingMask
        host.replaceSubview(self, with: fresh)
    }
}

@MainActor
final class MenuAction: NSObject {
    let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func perform(_ sender: Any?) {
        action()
    }
}

/// Кнопка-значок поверх медиа-блока: «⋯», ▶.
@MainActor
final class MediaOverlayButton: NSButton {
    convenience init(symbol: String, size: CGFloat, action: @escaping @MainActor () -> Void) {
        self.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size * 0.45, weight: .semibold))
        contentTintColor = .white
        wantsLayer = true
        layer?.cornerRadius = size == Metrics.Media.playButtonSize ? size / 2 : 4
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        let target = MenuAction(action)
        self.target = target
        self.action = #selector(MenuAction.perform(_:))
        objc_setAssociatedObject(self, &MediaOverlayButton.targetKey, target, .OBJC_ASSOCIATION_RETAIN)
    }

    nonisolated(unsafe) private static var targetKey: UInt8 = 0
}

/// Подпись под картинкой и видео: строка 14 серым; пустая видна только под мышью («Добавить подпись»).
@MainActor
final class MediaCaptionField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?

    init(text: String) {
        super.init(frame: .zero)
        stringValue = text
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: Metrics.Media.captionFontSize)
        textColor = Palette.textSecondary
        placeholderString = "Добавить подпись"
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        delegate = self
        setAccessibilityIdentifier("media-caption")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    func controlTextDidEndEditing(_ obj: Notification) {
        onCommit?(stringValue)
    }
}

/// Поверхность медиа-блока: заливка, картинка с заполнением и рамка, нарисованные самим видом — так они есть
/// и на снимках окна (`cacheDisplay`), которые содержимое слоя не видят.
@MainActor
final class MediaSurfaceView: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var image: CGImage? { didSet { needsDisplay = true } }
    var borderColor: NSColor? { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = Metrics.Media.cornerRadius
    /// Скруглены только левые углы (картинка у левого края карточки закладки).
    var roundsLeadingCornersOnly = false

    override var isFlipped: Bool { true }

    private var shape: NSBezierPath {
        guard roundsLeadingCornersOnly else { return NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius) }
        let path = NSBezierPath()
        let r = min(cornerRadius, bounds.height / 2, bounds.width / 2)
        path.move(to: NSPoint(x: bounds.maxX, y: bounds.minY))
        path.line(to: NSPoint(x: bounds.minX + r, y: bounds.minY))
        path.appendArc(withCenter: NSPoint(x: bounds.minX + r, y: bounds.minY + r), radius: r, startAngle: 270, endAngle: 180, clockwise: true)
        path.line(to: NSPoint(x: bounds.minX, y: bounds.maxY - r))
        path.appendArc(withCenter: NSPoint(x: bounds.minX + r, y: bounds.maxY - r), radius: r, startAngle: 180, endAngle: 90, clockwise: true)
        path.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY))
        path.close()
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = shape
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let fill {
            fill.setFill()
            bounds.fill()
        }
        if let image, let context = NSGraphicsContext.current?.cgContext {
            // Заполнение без искажения: лишнее по краям обрезается.
            let scale = max(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
            let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            context.saveGState()
            context.translateBy(x: 0, y: rect.maxY + rect.minY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            context.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        if let borderColor {
            borderColor.setStroke()
            let inset = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
            inset.lineWidth = 1
            inset.stroke()
        }
    }
}
