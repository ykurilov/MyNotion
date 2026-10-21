import AppKit
import Attachments
import Databases
import NotesCore
import UniformTypeIdentifiers
import VisualStyle

/// Окно ячейки «Файлы и медиа» (spec US2, сценарий 5; FR-314): сверху то, что уже в ячейке (щелчок открывает, «×»
/// убирает), под ним вкладки «Загрузить» (выбрать файл или перетащить из Finder) и «Ссылка» (поле и «Добавить»).
/// Файл копируется как файлы 002 (лимит 100 МБ, синхронизация, счётчик ссылок) — в фоне, окно не замирает.
@MainActor
final class FilesCellView: NSView, CellPopupContent {
    nonisolated static let factory = CellPopupFactory(kinds: [.files]) { FilesCellView(context: $0) }
    static let width: CGFloat = 320
    static let itemHeight: CGFloat = 30

    private enum Tab { case upload, link }

    private let context: CellPopupContext
    private var items: [FilesValue.Item] = []
    private var itemRows: [FileItemRow] = []
    private var tab = Tab.upload
    private let uploadTab = NSButton(title: "Загрузить", target: nil, action: nil)
    private let linkTab = NSButton(title: "Ссылка", target: nil, action: nil)
    private let chooseButton = NSButton(title: "Выбрать файл", target: nil, action: nil)
    private let dropHint = NSTextField(labelWithString: "или перетащите файлы сюда · до 100 МБ")
    private let linkField: PropertyPopupField
    private let addLinkButton = NSButton(title: "Добавить ссылку", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var isDropTarget = false { didSet { needsDisplay = true } }
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(context: CellPopupContext) {
        self.context = context
        linkField = PropertyPopupField(text: "", placeholder: "Вставьте ссылку на файл…", identifier: "files-link-field")
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        setAccessibilityIdentifier("files-popup")
        for (button, action) in [(uploadTab, #selector(showUpload)), (linkTab, #selector(showLink))] {
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            button.target = self
            button.action = action
            addSubview(button)
        }
        uploadTab.setAccessibilityIdentifier("files-tab-upload")
        linkTab.setAccessibilityIdentifier("files-tab-link")
        chooseButton.bezelStyle = .rounded
        chooseButton.target = self
        chooseButton.action = #selector(chooseFiles)
        chooseButton.setAccessibilityIdentifier("files-choose")
        addSubview(chooseButton)
        dropHint.font = NSFont.systemFont(ofSize: 12)
        dropHint.textColor = Palette.textSecondary
        dropHint.alignment = .center
        addSubview(dropHint)
        addSubview(linkField)
        linkField.onCommand = { [weak self] selector in
            guard let self else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): self.addLink(); return true
            case #selector(NSResponder.cancelOperation(_:)): self.context.close(); return true
            default: return false
            }
        }
        addLinkButton.bezelStyle = .rounded
        addLinkButton.keyEquivalent = ""
        addLinkButton.target = self
        addLinkButton.action = #selector(addLink)
        addLinkButton.setAccessibilityIdentifier("files-add-link")
        addSubview(addLinkButton)
        message.font = NSFont.systemFont(ofSize: 12)
        message.textColor = Palette.destructiveText
        message.setAccessibilityIdentifier("files-message")
        addSubview(message)
        registerForDraggedTypes([.fileURL])
        observer = NotificationCenter.default.addObserver(forName: DatabaseOperations.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var attachments: AttachmentStore {
        AttachmentStore(store: context.store, folder: AttachmentStore.folder(forDatabaseAt: context.store.database.url))
    }

    private var listHeight: CGFloat { CGFloat(items.count) * Self.itemHeight + (items.isEmpty ? 0 : 8) }
    private var messageHeight: CGFloat { message.stringValue.isEmpty ? 0 : 34 }

    var preferredSize: NSSize { NSSize(width: Self.width, height: listHeight + 36 + 92 + messageHeight) }
    override var fittingSize: NSSize { preferredSize }

    func focusFirstField() {
        if tab == .link { linkField.focus() } else { window?.makeFirstResponder(self) }
    }

    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { context.close() }

    private func reload() {
        let previous = preferredSize.height
        items = FilesValue.items(context.cellValue())
        itemRows.forEach { $0.removeFromSuperview() }
        itemRows = items.enumerated().map { index, item in
            let row = FileItemRow(item: item)
            row.onOpen = { [weak self] in self?.open(item) }
            row.onRemove = { [weak self] in
                guard let self else { return }
                self.context.attempt { try self.context.operations.removeFile(at: index, rowId: self.context.rowId, propertyId: self.context.propertyId) }
            }
            addSubview(row)
            return row
        }
        applyTab()
        if preferredSize.height != previous, window != nil { context.resize() }
    }

    private func applyTab() {
        uploadTab.contentTintColor = tab == .upload ? Palette.textPrimary : Palette.textSecondary
        linkTab.contentTintColor = tab == .link ? Palette.textPrimary : Palette.textSecondary
        chooseButton.isHidden = tab != .upload
        dropHint.isHidden = tab != .upload
        linkField.isHidden = tab != .link
        addLinkButton.isHidden = tab != .link
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        var y: CGFloat = items.isEmpty ? 0 : 4
        for row in itemRows {
            row.frame = NSRect(x: PropertyPopupMetrics.inset, y: y, width: bounds.width - 2 * PropertyPopupMetrics.inset, height: Self.itemHeight)
            y += Self.itemHeight
        }
        if !items.isEmpty { y += 4 }
        uploadTab.frame = NSRect(x: 12, y: y + 6, width: uploadTab.intrinsicContentSize.width, height: 24)
        linkTab.frame = NSRect(x: uploadTab.frame.maxX + 14, y: y + 6, width: linkTab.intrinsicContentSize.width, height: 24)
        y += 36
        let inset: CGFloat = 12
        chooseButton.frame = NSRect(x: inset, y: y + 10, width: bounds.width - 2 * inset, height: 28)
        dropHint.frame = NSRect(x: inset, y: y + 48, width: bounds.width - 2 * inset, height: 18)
        linkField.frame = NSRect(x: inset - PropertyPopupMetrics.inset, y: y + 6, width: bounds.width - 2 * inset + 2 * PropertyPopupMetrics.inset, height: 36)
        addLinkButton.frame = NSRect(x: (bounds.width - 160) / 2, y: y + 48, width: 160, height: 28)
        y += 92
        message.frame = NSRect(x: inset, y: y, width: bounds.width - 2 * inset, height: messageHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let tabsY = listHeight
        Palette.popupDivider.setFill()
        if !items.isEmpty { NSRect(x: 0, y: tabsY - 1, width: bounds.width, height: 1).fill() }
        NSRect(x: 0, y: tabsY + 35, width: bounds.width, height: 1).fill()
        // Подчёркивание активной вкладки.
        Palette.textPrimary.setFill()
        let active = tab == .upload ? uploadTab.frame : linkTab.frame
        NSRect(x: active.minX, y: tabsY + 33, width: active.width, height: 2).fill()
        if isDropTarget {
            Palette.blockSelection.setFill()
            NSBezierPath(roundedRect: NSRect(x: 8, y: tabsY + 40, width: bounds.width - 16, height: 84), xRadius: 6, yRadius: 6).fill()
        }
    }

    // MARK: Действия

    @objc private func showUpload() {
        tab = .upload
        applyTab()
    }

    @objc private func showLink() {
        tab = .link
        applyTab()
        linkField.focus()
    }

    @objc private func addLink() {
        guard let link = FilesValue.link(linkField.text) else {
            show("Это не похоже на ссылку")
            return
        }
        context.attempt { try context.operations.addFiles([link], rowId: context.rowId, propertyId: context.propertyId) }
        linkField.field.stringValue = ""
        show("")
    }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// Скопировать файлы в фоне и положить в ячейку одной правкой; больше 100 МБ — сообщение, остальные берутся.
    func importFiles(_ urls: [URL]) {
        let attachments = attachments
        // Окно могло закрыться, пока файл копировался (щелчок в окне выбора файла): правка всё равно ложится в ячейку.
        let context = context
        show("Копируется…", isError: false)
        Task { [weak self] in
            let outcome: (refs: [AttachmentRef], errors: [String]) = await Task.detached(priority: .userInitiated) {
                var refs: [AttachmentRef] = []
                var errors: [String] = []
                for url in urls {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do { refs.append(try attachments.importFile(at: url)) } catch { errors.append(error.localizedDescription) }
                }
                return (refs, errors)
            }.value
            if !outcome.refs.isEmpty {
                context.attempt { try context.operations.addFiles(outcome.refs.map(FilesValue.Item.file), rowId: context.rowId, propertyId: context.propertyId) }
            }
            self?.show(outcome.errors.first ?? "")
        }
    }

    private func open(_ item: FilesValue.Item) {
        switch item {
        case .file(let ref):
            if case .ready(let url) = attachments.availability(of: ref.id) {
                NSWorkspace.shared.open(url)
            } else {
                show("Файл ещё едет с другого Mac")
            }
        case .link(let url, _):
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        case .other:
            break
        }
    }

    private func show(_ text: String, isError: Bool = true) {
        let previous = preferredSize.height
        message.stringValue = text
        message.textColor = isError ? Palette.destructiveText : Palette.textSecondary
        needsLayout = true
        if preferredSize.height != previous, window != nil { context.resize() }
    }

    // MARK: Перетаскивание из Finder

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isDropTarget = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { isDropTarget = false }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTarget = false
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        importFiles(urls)
        return true
    }
}

/// Строка файла в окне: значок (картинка — уменьшенной копией), имя, «×» при наведении.
@MainActor
final class FileItemRow: NSView {
    let item: FilesValue.Item
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    private var isHovered = false { didSet { needsDisplay = true } }

    init(item: FilesValue.Item) {
        self.item = item
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.name)
        setAccessibilityIdentifier("file-item-\(item.name)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var removeRect: NSRect { NSRect(x: bounds.maxX - 28, y: (bounds.height - 20) / 2, width: 20, height: 20) }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: Metrics.PopupMenu.rowCornerRadius, yRadius: Metrics.PopupMenu.rowCornerRadius).fill()
        }
        let icon = NSRect(x: 8, y: (bounds.height - 20) / 2, width: 20, height: 20)
        let symbol: String
        switch item {
        case .file: symbol = FilesValue.isImage(item) ? "photo" : "doc"
        case .link: symbol = "link"
        case .other: symbol = "questionmark.square"
        }
        ActionMenuIcon.draw(symbol, color: Palette.textSecondary, in: icon)
        let style = Typography.popupMenuTitle
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        NSAttributedString(string: item.name, attributes: [.font: style.font, .foregroundColor: Palette.textPrimary, .paragraphStyle: paragraph])
            .draw(in: NSRect(x: icon.maxX + 8, y: (bounds.height - style.lineHeight) / 2, width: removeRect.minX - icon.maxX - 12, height: style.lineHeight))
        if isHovered { ActionMenuIcon.draw("xmark", color: Palette.textSecondary, in: removeRect, inkSide: 10) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if removeRect.insetBy(dx: -4, dy: -4).contains(point) { onRemove?() } else { onOpen?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }
}
