import AppKit
import NotesCore
import UniformTypeIdentifiers
import VisualStyle

/// Как вставить ссылку на ролик (contracts/blocks-and-keys.md, «Видео»): меню после вставки адреса, как у Notion.
enum PastedLinkChoice: CaseIterable {
    case embed
    case bookmark
    case link

    var title: String {
        switch self {
        case .embed: "Встроить видео"
        case .bookmark: "Закладка"
        case .link: "Ссылка"
        }
    }

    var menuItem: PopupMenuItem {
        switch self {
        case .embed: PopupMenuItem(title: title, icon: .symbol("play.rectangle"), keywords: [], action: .setKind(.video))
        case .bookmark: PopupMenuItem(title: title, icon: .symbol("bookmark"), keywords: [], action: .setKind(.bookmark))
        case .link: PopupMenuItem(title: title, icon: .symbol("link"), keywords: [], action: .setKind(.paragraph))
        }
    }

    init?(_ item: PopupMenuItem) {
        guard let choice = Self.allCases.first(where: { $0.menuItem == item }) else { return nil }
        self = choice
    }
}

/// Состояние вставки медиа-блоков в странице.
@MainActor
final class MediaInsertionState {
    /// Только что вставленный адрес ролика: в каком блоке, где в тексте страницы.
    struct PastedLink {
        var blockId: UUID
        var url: URL
        var range: NSRange
    }

    var pastedLink: PastedLink?
    var pastedLinkMenu: PopupMenuWindow?
    var insertionPopover: NSPopover?
    /// Последняя ошибка вставки (больше 100 МБ, нет доступа) — показана Юрию.
    var lastError: String?

    func closePastedLinkMenu() {
        pastedLink = nil
        pastedLinkMenu?.hide()
        pastedLinkMenu = nil
    }
}

extension PageTextView {
    var lastAttachmentError: String? { mediaInsertion.lastError }

    // MARK: Файлы из Finder и буфера

    /// Скопировать файлы и вставить блоки: картинка — картинка, видео — видео, прочее — файл. Пустой абзац под
    /// курсором заменяется, иначе блоки встают под ним. Больше 100 МБ — сообщение, блок не создаётся.
    func insertFiles(_ urls: [URL], at index: Int, as forcedKind: BlockKind? = nil) async {
        guard let services = MediaBlocks.services else { return }
        var drafts: [BlockDraft] = []
        for url in urls {
            do {
                let ref = try await services.importFile(at: url)
                drafts.append(Self.mediaDraft(for: ref, file: url, forcedKind: forcedKind))
            } catch {
                showAttachmentError(error)
            }
        }
        insertMediaDrafts(drafts, at: index, actionName: "Вставить файл")
    }

    /// ⌘V: файлы, скопированные в Finder, или картинка из буфера (PNG). `false` — в буфере ни того ни другого.
    @discardableResult
    func pasteAttachments(from pasteboard: NSPasteboard) async -> Bool {
        guard let index = mapper.blockPosition(at: selectedRange().location)?.index, let services = MediaBlocks.services else { return false }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            await insertFiles(urls, at: index)
            return true
        }
        guard let png = Self.pastedPNG(from: pasteboard) else { return false }
        do {
            let ref = try await services.importData(png.data, name: "Картинка.png", contentType: UTType.png.identifier)
            var draft = Self.mediaDraft(for: ref, file: nil, forcedKind: .image)
            draft.props?.pixelSize = png.size
            insertMediaDrafts([draft], at: index, actionName: "Вставить картинку")
        } catch {
            showAttachmentError(error)
        }
        return true
    }

    /// Есть ли в буфере то, что вставляется блоком: файлы Finder или картинка без текста.
    static func pasteboardHasAttachments(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        return pasteboard.string(forType: .string) == nil && pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    private static func pastedPNG(from pasteboard: NSPasteboard) -> (data: Data, size: PixelSize)? {
        guard let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        let png = type == .png ? data : rep.representation(using: .png, properties: [:])
        return png.map { ($0, PixelSize(width: rep.pixelsWide, height: rep.pixelsHigh)) }
    }

    /// Черновик блока для файла: тип — по типу файла или тот, что выбран в меню «/».
    static func mediaDraft(for ref: AttachmentRef, file: URL?, forcedKind: BlockKind?) -> BlockDraft {
        let type = UTType(ref.contentType)
        let kind = forcedKind ?? (type?.conforms(to: .image) == true ? .image
            : type?.conforms(to: .audiovisualContent) == true ? .video : .file)
        var props = BlockProps()
        props.attachment = ref
        if kind == .video { props.videoSource = .file }
        if kind == .image, let file, let size = ImageThumbnailCache.pixelSize(of: file) {
            props.pixelSize = PixelSize(width: size.width, height: size.height)
        }
        return BlockDraft(id: nil, kind: kind, props: props)
    }

    /// Вставить блоки одним шагом ⌘Z: пустой абзац под курсором заменяется, иначе — под ним; под последним
    /// блоком страницы остаётся пустой абзац для набора.
    func insertMediaDrafts(_ drafts: [BlockDraft], at index: Int, actionName: String) {
        guard !drafts.isEmpty, !document.blocks.isEmpty else { return }
        commitEdits()
        let index = min(max(0, index), document.blocks.count - 1)
        let block = document.blocks[index]
        let replaces = block.kind == .paragraph && block.text.string.isEmpty
        var list = (replaces ? [] : [BlockDraft(block)]) + drafts.map { draft in
            var draft = draft
            draft.indent = block.indent
            return draft
        }
        let isLast = index == document.blocks.count - 1
        if isLast { list.append(BlockDraft(id: nil, kind: .paragraph, indent: block.indent)) }
        changeBlocks(index..<index + 1, to: list, actionName: actionName)
        let next = index + list.count - (isLast ? 1 : 0)
        if next < document.blocks.count { setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: next), length: 0)) }
    }

    private func showAttachmentError(_ error: any Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        mediaInsertion.lastError = message
        guard let window, window.isVisible else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Понятно")
        alert.beginSheetModal(for: window)
    }

    // MARK: Ссылки

    /// Видео YouTube или Vimeo, закладка: блок с адресом сразу, название и картинка приходят следом
    /// и не становятся отдельным шагом ⌘Z.
    func insertLink(_ url: URL, as kind: BlockKind, at index: Int) async {
        guard let draft = linkDraft(url, as: kind) else { return }
        insertMediaDrafts([draft], at: index, actionName: kind == .video ? "Встроить видео" : "Закладка")
        guard let id = draftedBlockId(near: index, kind: kind, url: url) else { return }
        await fetchPreview(for: id)
    }

    private func linkDraft(_ url: URL, as kind: BlockKind) -> BlockDraft? {
        var props = BlockProps()
        props.url = url
        if kind == .video {
            guard let source = MediaBlocks.services?.videoSource(for: url) else { return nil }
            props.videoSource = source
        }
        return BlockDraft(id: nil, kind: kind, props: props)
    }

    private func draftedBlockId(near index: Int, kind: BlockKind, url: URL) -> UUID? {
        document.blocks[max(0, index)...].first { $0.kind == kind && $0.props.url == url }?.id
    }

    /// Данные карточки закладки или обложка ролика.
    func fetchPreview(for id: UUID) async {
        guard let services = MediaBlocks.services, let block = document.blocks.first(where: { $0.id == id }),
              let url = block.props.url else { return }
        let preview: MediaLinkPreview? = block.kind == .bookmark ? await services.linkPreview(for: url) : await services.videoCover(for: url)
        if let preview { applyFetchedPreview(preview, toBlock: id) }
    }

    /// Данные с сайта — в блок, без шага ⌘Z: их принесла сеть, а не правка Юрия.
    func applyFetchedPreview(_ preview: MediaLinkPreview, toBlock id: UUID) {
        guard let index = document.index(ofBlock: id) else { return }
        var draft = BlockDraft(document.blocks[index])
        var props = draft.props ?? BlockProps()
        if document.blocks[index].kind == .bookmark {
            props.title = preview.title
            props.description = preview.description
            props.image = preview.image
            props.iconAttachment = preview.icon
            props.fetchedAt = Date()
        } else {
            if props.title == nil { props.title = preview.title }
            props.poster = preview.image ?? props.poster
        }
        draft.props = props
        replaceBlockQuietly(at: index, with: draft)
    }

    /// Свойства блока-вложения из сети: без шага ⌘Z и не закрывая открытых меню (Юрий мог уже набирать «/»).
    /// Абзац вложения той же длины — выделение остаётся на месте.
    private func replaceBlockQuietly(at index: Int, with draft: BlockDraft) {
        let blocks = document.blocks
        let characters = mapper.characterRange(ofBlocksAt: index..<index + 1)
        let selection = selectedRanges
        _ = document.replaceBlocks(after: index > 0 ? blocks[index - 1].id : nil,
                                   before: index + 1 < blocks.count ? blocks[index + 1].id : nil,
                                   with: [draft], movedBlockIds: [], origin: textStorage)
        mapper.renderBlocks(index..<index + 1, replacing: characters)
        selectedRanges = selection
        blockViews.update()
    }

    /// «Обновить» в меню закладки.
    func refreshBookmark(ofBlock id: UUID) {
        Task { await fetchPreview(for: id) }
    }

    // MARK: Меню вставленной ссылки на ролик

    /// После вставки адреса YouTube или Vimeo в пустую строку — меню «Встроить видео / Закладка / Ссылка».
    func offerPastedVideoLink(_ text: String, at location: Int) {
        guard let url = InlineFormatting.pastedLinkURL(from: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              MediaBlocks.services?.videoSource(for: url) != nil,
              let position = mapper.blockPosition(at: location) else { return }
        let block = document.blocks[position.index]
        guard block.kind == .paragraph, block.text.string == text else { return }
        let range = NSRange(location: mapper.paragraphStart(ofBlockAt: position.index), length: (text as NSString).length)
        mediaInsertion.closePastedLinkMenu()
        mediaInsertion.pastedLink = .init(blockId: block.id, url: url, range: range)
        guard let parent = window else { return }
        let menu = PopupMenuWindow(style: .block)
        menu.menuView.setItems(PastedLinkChoice.allCases.map(\.menuItem))
        menu.menuView.onChoose = { [weak self] item in
            guard let choice = PastedLinkChoice(item) else { return }
            self?.choosePastedLink(choice)
        }
        menu.show(below: firstRect(forCharacterRange: NSRange(location: NSMaxRange(range), length: 0), actualRange: nil), parent: parent)
        mediaInsertion.pastedLinkMenu = menu
    }

    var pastedLinkMenuTitles: [String]? {
        mediaInsertion.pastedLink == nil ? nil : PastedLinkChoice.allCases.map(\.title)
    }

    func choosePastedLink(_ choice: PastedLinkChoice) {
        guard let pasted = mediaInsertion.pastedLink, let index = document.index(ofBlock: pasted.blockId) else { return }
        mediaInsertion.closePastedLinkMenu()
        switch choice {
        case .link:
            setSelectedRange(pasted.range)
            setLink(pasted.url)
            setSelectedRange(NSRange(location: NSMaxRange(pasted.range), length: 0))
        case .embed, .bookmark:
            let kind: BlockKind = choice == .embed ? .video : .bookmark
            guard var draft = linkDraft(pasted.url, as: kind) else { return }
            draft.id = document.blocks[index].id
            draft.indent = document.blocks[index].indent
            var list = [draft]
            if index == document.blocks.count - 1 { list.append(BlockDraft(id: nil, kind: .paragraph, indent: draft.indent)) }
            changeBlocks(index..<index + 1, to: list, actionName: choice.title)
            if index + 1 < document.blocks.count {
                setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: index + 1), length: 0))
            }
            let id = pasted.blockId
            Task { [weak self] in await self?.fetchPreview(for: id) }
        }
    }

    // MARK: Окно «Выбрать файл… / Вставить ссылку»

    /// «/» → «Картинка», «Файл», «Видео», «Закладка»: окно у блока.
    func beginAttachmentInsertion(_ kind: BlockKind, at index: Int) {
        commitEdits()
        guard let window, index < document.blocks.count else { return }
        let anchor = firstRect(forCharacterRange: NSRange(location: mapper.paragraphStart(ofBlockAt: index), length: 0), actualRange: nil)
        let controller = AttachmentInsertionController(kind: kind) { [weak self] result in
            guard let self else { return }
            self.mediaInsertion.insertionPopover?.close()
            self.mediaInsertion.insertionPopover = nil
            self.window?.makeFirstResponder(self)
            let blockId = self.document.blocks[min(index, self.document.blocks.count - 1)].id
            Task { [weak self] in
                guard let self, let index = self.document.index(ofBlock: blockId) else { return }
                switch result {
                case .file(let url): await self.insertFiles([url], at: index, as: kind)
                case .link(let url): await self.insertLinked(url, as: kind, at: index)
                }
            }
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        let local = convert(window.convertFromScreen(anchor), from: nil)
        popover.show(relativeTo: NSRect(x: local.minX, y: local.minY, width: 1, height: max(1, local.height)), of: self, preferredEdge: .maxY)
        mediaInsertion.insertionPopover = popover
    }

    /// «Вставить ссылку»: ролик и сайт — блоком по адресу; картинка и файл — скачиваются в копию на Mac.
    private func insertLinked(_ url: URL, as kind: BlockKind, at index: Int) async {
        guard let services = MediaBlocks.services else { return }
        if kind == .bookmark || (kind == .video && services.videoSource(for: url) != nil) {
            await insertLink(url, as: kind, at: index)
            return
        }
        do {
            let ref = try await services.downloadFile(from: url)
            insertMediaDrafts([Self.mediaDraft(for: ref, file: nil, forcedKind: kind)], at: index, actionName: "Вставить файл")
        } catch {
            showAttachmentError(error)
        }
    }

    // MARK: Правки медиа-блока

    /// Ширина картинки или видео — доля колонки 10–100 %.
    func setMediaWidth(_ fraction: Double, ofBlock id: UUID) {
        let clamped = ImageBlockView.clampedWidth(fraction)
        editMediaBlock(id, actionName: "Ширина") { draft in draft.props?.width = clamped >= 0.999 ? nil : clamped }
    }

    /// Подпись картинки и видео — текст блока.
    func setMediaCaption(_ text: String, ofBlock id: UUID) {
        editMediaBlock(id, actionName: "Подпись") { draft in draft.text = InlineText(text.replacingOccurrences(of: "\n", with: " ")) }
    }

    /// «Переименовать» файл: имя в описании файла, его видят все Mac; копия на диске не трогается.
    func renameAttachment(_ name: String, ofBlock id: UUID) {
        editMediaBlock(id, actionName: "Переименовать") { draft in draft.props?.attachment?.name = name }
    }

    /// «Заменить» картинку: новый файл в том же блоке.
    func replaceMedia(ofBlock id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let services = MediaBlocks.services else { return }
        Task { [weak self] in
            do {
                let ref = try await services.importFile(at: url)
                let replacement = Self.mediaDraft(for: ref, file: url, forcedKind: .image)
                self?.editMediaBlock(id, actionName: "Заменить картинку") { draft in
                    draft.props?.attachment = ref
                    draft.props?.pixelSize = replacement.props?.pixelSize
                }
            } catch {
                self?.showAttachmentError(error)
            }
        }
    }

    private func editMediaBlock(_ id: UUID, actionName: String, _ change: (inout BlockDraft) -> Void) {
        commitEdits()
        guard let index = document.index(ofBlock: id) else { return }
        var draft = BlockDraft(document.blocks[index])
        if draft.props == nil { draft.props = BlockProps() }
        change(&draft)
        changeBlocks(index..<index + 1, to: [draft], actionName: actionName)
    }

    /// Переложить строку блока: пустую подпись начали или кончили править, высота строки другая. Не правка — без ⌘Z.
    func relayoutBlockView(_ id: UUID) {
        guard let index = document.index(ofBlock: id) else { return }
        let selection = selectedRanges
        mapper.renderBlocks(index..<index + 1, replacing: mapper.characterRange(ofBlocksAt: index..<index + 1))
        selectedRanges = selection
        blockViews.update()
    }

    /// ⌘V доступна, и когда в буфере только картинка или файлы Finder: «Вставить» не выключается.
    override public var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        let types = super.readablePasteboardTypes
        return types + [.fileURL, .png, .tiff].filter { !types.contains($0) }
    }

    // MARK: Перетаскивание из Finder

    override public var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        let types = super.acceptableDragTypes
        return types.contains(.fileURL) ? types : types + [.fileURL]
    }

    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard sender.draggingSource as? NSView == nil || !(sender.draggingSource is PageTextView),
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        let location = characterIndexForInsertion(at: point)
        guard let index = mapper.blockPosition(at: min(location, max(0, (textStorage?.length ?? 1) - 1)))?.index else { return false }
        Task { [weak self] in await self?.insertFiles(urls, at: index) }
        return true
    }
}

/// Содержимое окна вставки: «Выбрать файл…» и поле «Вставить ссылку»; у закладки — только адрес.
@MainActor
final class AttachmentInsertionController: NSViewController {
    enum Result {
        case file(URL)
        case link(URL)
    }

    let kind: BlockKind
    let onResult: (Result) -> Void
    private let field = NSTextField()

    init(kind: BlockKind, onResult: @escaping (Result) -> Void) {
        self.kind = kind
        self.onResult = onResult
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        if kind != .bookmark {
            let choose = NSButton(title: "Выбрать файл…", target: self, action: #selector(chooseFile))
            choose.setAccessibilityIdentifier("insert-choose-file")
            stack.addArrangedSubview(choose)
        }
        field.placeholderString = kind == .bookmark ? "Вставьте адрес сайта" : "Вставить ссылку"
        field.setAccessibilityIdentifier("insert-link-field")
        field.target = self
        field.action = #selector(submitLink)
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        stack.addArrangedSubview(field)
        let submit = NSButton(title: kind == .bookmark ? "Создать закладку" : "Вставить", target: self, action: #selector(submitLink))
        submit.keyEquivalent = "\r"
        submit.setAccessibilityIdentifier("insert-link-submit")
        stack.addArrangedSubview(submit)
        view = stack
    }

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        switch kind {
        case .image: panel.allowedContentTypes = [.image]
        case .video: panel.allowedContentTypes = [.movie]
        default: break
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onResult(.file(url))
    }

    @objc private func submitLink() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.contains("://") ? text : "https://" + text), url.host != nil else {
            NSSound.beep()
            return
        }
        onResult(.link(url))
    }
}
