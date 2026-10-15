import AppKit
import NotesCore
import VisualStyle

/// Текст страницы (FR-013, research R2): один `NSTextView` на TextKit 2, абзац = блок.
/// Системное поведение текста — выделение, ⌘Z, проверка орфографии, ввод с IME, ⌘F — от `NSTextView`;
/// правки уходят в `PageDocument` через `PageTextStorageMapper`. Над текстом — шапка с иконкой и названием.
@MainActor
public final class PageTextView: NSTextView {
    public let document: PageDocument
    public let header: PageHeaderView
    private(set) var mapper: PageTextStorageMapper!
    let emptyParagraphHint = NSTextField(labelWithString: "Введите «/» для выбора блока")
    /// Блок, у которого сейчас видна подсказка под курсором: его фрагмент свою подсказку не рисует.
    private(set) var emptyHintBlockID: UUID? {
        didSet { if emptyHintBlockID != oldValue { redrawBlocks([oldValue, emptyHintBlockID].compactMap { $0 }) } }
    }
    /// Поле-надпись рисует текст на 2 правее своего края.
    static let hintLabelTextInset: CGFloat = 2
    /// Проверка орфографии при наборе включена в меню «Правописание» (FR-013).
    private var spellCheckingWanted = true
    /// Подложка под «/» с поиском, пока открыто меню «/».
    let slashQueryHighlight = NSView()

    /// Куда поставить курсор, когда страница появится в окне.
    public enum InitialFocus { case title, body }
    private var pendingFocus: InitialFocus?
    /// Страница показана и принимает ввод.
    public var onReady: (@MainActor () -> Void)?
    /// Отмена, когда окна нет или оно своей не даёт (проверки без приложения).
    public var fallbackUndoManager: UndoManager?
    /// Названия и иконки страниц, на которые ссылаются блоки-подстраницы.
    public var linkedPages: [UUID: LinkedPage] = [:] {
        didSet { if linkedPages != oldValue { redrawBlockDecorations() } }
    }
    /// Щелчок по блоку-подстранице: открыть страницу.
    public var onOpenPage: (@MainActor (UUID) -> Void)?
    /// ⌘-щелчок по ссылке: открыть адрес (по умолчанию — в браузере по умолчанию).
    public var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    let layoutDelegate = BlockLayoutDelegate()
    let popups = EditorPopupController()
    lazy var blockHandles = BlockHandlesOverlay(textView: self)

    public init(document: PageDocument, initialFocus: InitialFocus) {
        self.document = document
        header = PageHeaderView(page: document.page)
        pendingFocus = initialFocus

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: Metrics.Page.columnWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = Metrics.Page.blockHorizontalPadding
        layoutManager.textContainer = container
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.Page.columnWidth, height: 0), textContainer: container)
        layoutDelegate.textView = self
        layoutManager.delegate = layoutDelegate
        popups.textView = self

        configureTextBehaviour()
        mapper = PageTextStorageMapper(document: document, textStorage: textStorage!)
        mapper.load()
        // Отмена правки текста не зовёт didChangeText: забрать её в документ сразу после ⌘Z и ⇧⌘Z.
        for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoManagerDidRestore(_:)), name: name, object: nil)
        }

        addSubview(header)
        slashQueryHighlight.wantsLayer = true
        slashQueryHighlight.layer?.cornerRadius = Metrics.PopupMenu.slashQueryCornerRadius
        slashQueryHighlight.isHidden = true
        addSubview(slashQueryHighlight)
        addSubview(emptyParagraphHint)
        emptyParagraphHint.textColor = Palette.textSecondary
        emptyParagraphHint.isHidden = true
        header.onTitleChange = { [weak self] title in
            self?.document.setTitle(title)
            self?.layoutColumn()
        }
        header.onTitleEnter = { [weak self] in self?.focusBody(at: 0) }
        layoutColumn()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    private func configureTextBehaviour() {
        isRichText = true
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isContinuousSpellCheckingEnabled = spellCheckingWanted
        isGrammarCheckingEnabled = false
        drawsBackground = true
        backgroundColor = Palette.pageBackground
        insertionPointColor = Palette.textPrimary
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        setAccessibilityIdentifier("page-body")
    }

    // MARK: Правки

    public override var undoManager: UndoManager? {
        fallbackUndoManager ?? super.undoManager
    }

    @objc private func undoManagerDidRestore(_ notification: Notification) {
        guard notification.object as? UndoManager === undoManager, mapper.hasPendingEdits else { return }
        let blockCount = document.blocks.count
        mapper.commitPendingEdits()
        if document.blocks.count != blockCount { redrawBlockDecorations() }
        updateEmptyParagraphHint()
    }

    public override func didChangeText() {
        super.didChangeText()
        // Посреди набора с помощью IME текст ещё не окончательный.
        guard !hasMarkedText() else { return }
        let blockCount = document.blocks.count
        mapper.commitPendingEdits()
        if document.blocks.count != blockCount { redrawBlockDecorations() }
        updateEmptyParagraphHint()
        textDidChangeForPopups()
    }

    /// Вставка: адрес поверх выделения — ссылка, текст других программ — с поддерживаемым оформлением.
    public override func paste(_ sender: Any?) {
        paste(from: .general)
    }

    public override func pasteAsRichText(_ sender: Any?) {
        paste(from: .general)
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        hideBlockHandles()
        if typed == " ", replacementRange.location == NSNotFound, !hasMarkedText(), applyMarkdownShortcut() { return }
        if replacementRange.location == NSNotFound, !hasMarkedText(), !typed.isEmpty, !typed.hasPrefix("\n"), isCaretInPageLink {
            // В блоке-подстранице текста нет: набранное уходит в новый абзац под ним.
            super.insertText("\n" + typed, replacementRange: replacementRange)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
        if typed == "/" { openSlashMenuAfterTypedSlash() }
    }

    /// Курсор стоит в блоке-подстранице (у него свой абзац без символов).
    private var isCaretInPageLink: Bool {
        let selection = selectedRange()
        guard selection.length == 0, let position = mapper.blockPosition(at: selection.location) else { return false }
        return document.blocks[position.index].kind == .pageLink
    }

    public override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText(), handleBackspaceAtBlockStart() { return }
        super.deleteBackward(sender)
    }

    public override func insertNewline(_ sender: Any?) {
        if !hasMarkedText(), handleNewlineInEmptyItem() { return }
        super.insertNewline(sender)
    }

    public override func insertTab(_ sender: Any?) { perform(.indent) }
    public override func insertBacktab(_ sender: Any?) { perform(.outdent) }
    public override func moveParagraphBackwardAndModifySelection(_ sender: Any?) { perform(.moveBlocksUp) }
    public override func moveParagraphForwardAndModifySelection(_ sender: Any?) { perform(.moveBlocksDown) }

    public override func keyDown(with event: NSEvent) {
        hideBlockHandles()
        if !hasMarkedText(), let command = EditorKeyBindings.command(for: event) {
            perform(command)
            return
        }
        super.keyDown(with: event)
    }

    /// ⌘B, ⌘I, ⇧⌘X, ⌘E, ⌘Enter — раньше меню: окно спрашивает поле ввода первым.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, !hasMarkedText(), let command = EditorKeyBindings.command(for: event) {
            perform(command)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func doCommand(by selector: Selector) {
        if handlePopupCommand(selector) { return }
        super.doCommand(by: selector)
    }

    public override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        // Последний перевод строки остаётся: на нём держится вид последнего блока (PageTextStorageMapper).
        let length = textStorage?.length ?? 0
        if let replacement = replacementString, affectedCharRange.length > 0, NSMaxRange(affectedCharRange) == length,
           !replacement.hasSuffix("\n") {
            return false
        }
        // В абзац блока-подстраницы символы не попадают, кроме перевода строки в его начале.
        if let replacement = replacementString, !replacement.isEmpty, !replacement.hasPrefix("\n"), affectedCharRange.length == 0,
           !mapper.hasPendingEdits, let position = mapper.blockPosition(at: affectedCharRange.location),
           document.blocks[position.index].kind == .pageLink {
            return false
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    /// Правка текста как от пользователя: с отменой и передачей документу.
    @discardableResult
    func replaceText(in range: NSRange, with text: NSAttributedString) -> Bool {
        guard let textStorage, shouldChangeText(in: range, replacementString: text.string) else { return false }
        textStorage.replaceCharacters(in: range, with: text)
        didChangeText()
        return true
    }

    @discardableResult
    func replaceText(in range: NSRange, with string: String) -> Bool {
        replaceText(in: range, with: NSAttributedString(string: string, attributes: typingAttributes))
    }

    // MARK: Действия над блоками

    /// Выполнить действие редактора над блоками под курсором или выделением.
    public func perform(_ command: EditorCommand) {
        guard !hasMarkedText() else { return }
        switch command {
        case .indent: indentSelectedBlocks(by: 1)
        case .outdent: indentSelectedBlocks(by: -1)
        case .moveBlocksUp: moveSelectedBlocks(by: -1)
        case .moveBlocksDown: moveSelectedBlocks(by: 1)
        case .toggleChecked: toggleCheckedSelectedBlocks()
        case .toggleInline(let format): toggleInline(format)
        case .setKind(let kind):
            commitEdits()
            if let selected = selectedBlockRange() { setKind(kind, ofBlocksAt: selected) }
        }
    }

    /// Блоки под курсором или выделением.
    func selectedBlockRange() -> Range<Int>? {
        let selection = selectedRange()
        guard let first = mapper.blockPosition(at: selection.location) else { return nil }
        guard selection.length > 0, let last = mapper.blockPosition(at: NSMaxRange(selection)) else {
            return first.index..<first.index + 1
        }
        // Выделение до начала следующего абзаца этот абзац не захватывает.
        let lastIndex = last.offset == 0 && last.index > first.index ? last.index - 1 : last.index
        return first.index..<lastIndex + 1
    }

    func setKind(_ kind: BlockKind, ofBlocksAt range: Range<Int>) {
        guard kind != .pageLink else { return }
        let drafts = document.blocks[range].map { block in
            var draft = BlockDraft(block)
            draft.kind = kind
            if kind != .checkbox { draft.isChecked = false }
            return draft
        }
        changeBlocks(range, to: drafts, actionName: "Тип блока")
    }

    func removeBlocks(at range: Range<Int>) {
        commitEdits()
        guard !range.isEmpty else { return }
        if range.count >= document.blocks.count {
            // На странице всегда остаётся хотя бы один блок: пустой абзац.
            changeBlocks(0..<document.blocks.count, to: [BlockDraft(id: document.blocks[0].id)], actionName: "Удалить блок")
            return
        }
        changeBlocks(range, to: [], actionName: "Удалить блок")
    }

    private func toggleCheckedSelectedBlocks() {
        commitEdits()
        guard let selected = selectedBlockRange() else { return }
        let checkboxes = selected.filter { document.blocks[$0].kind == .checkbox }
        guard let first = checkboxes.first, let last = checkboxes.last else { return }
        let checked = !checkboxes.allSatisfy { document.blocks[$0].isChecked }
        let range = first..<last + 1
        let drafts = document.blocks[range].map { block in
            var draft = BlockDraft(block)
            if block.kind == .checkbox { draft.isChecked = checked }
            return draft
        }
        changeBlocks(range, to: drafts, actionName: checked ? "Отметить" : "Снять отметку")
    }

    /// Переключить отметку чекбокса (щелчок по квадрату).
    public func toggleCheckbox(ofBlock id: UUID) {
        commitEdits()
        guard let index = document.index(ofBlock: id), document.blocks[index].kind == .checkbox else { return }
        var draft = BlockDraft(document.blocks[index])
        draft.isChecked.toggle()
        changeBlocks(index..<index + 1, to: [draft], actionName: draft.isChecked ? "Отметить" : "Снять отметку")
    }

    // MARK: Единая отмена (FR-012)

    /// Заменить блоки `range` документа черновиками `drafts` одним шагом отмены: тип, вложенность,
    /// перестановка, оформление. Текст на экране переписывается по блокам, курсор остаётся у своего блока.
    /// ⌘Z вызывает то же самое с прежними черновиками, поэтому правки текста и блоков отменяются одной цепочкой.
    func changeBlocks(_ range: Range<Int>, to drafts: [BlockDraft], moved: Set<UUID> = [], actionName: String) {
        commitEdits()
        let blocks = document.blocks
        guard range.lowerBound >= 0, range.upperBound <= blocks.count, !(range.count == blocks.count && drafts.isEmpty) else { return }
        let previous = blocks[range].map(BlockDraft.init)
        guard previous != drafts || !moved.isEmpty else { return }
        breakUndoCoalescing()

        let anchors = selectionAnchors()
        let touchesEnd = range.upperBound == blocks.count
        let characters = mapper.characterRange(ofBlocksAt: range)

        let previousId = range.lowerBound > 0 ? blocks[range.lowerBound - 1].id : nil
        let nextId = touchesEnd ? nil : blocks[range.upperBound].id
        let ids = document.replaceBlocks(after: previousId, before: nextId, with: drafts, movedBlockIds: moved)
        let changed = range.lowerBound..<range.lowerBound + ids.count
        mapper.renderBlocks(changed, replacing: characters)

        restoreSelection(anchors, fallbackBlock: min(range.lowerBound, document.blocks.count - 1))
        redrawBlockDecorations()
        updateEmptyParagraphHint()
        closePopups()

        if let undoManager {
            let restoredMoved = Set(ids).intersection(moved)
            undoManager.registerUndo(withTarget: self) { textView in
                textView.changeBlocks(changed, to: previous, moved: restoredMoved, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }
    }

    /// Где выделение относительно блоков: id блока и смещение в его тексте для начала и конца.
    private func selectionAnchors() -> (start: (UUID, Int), end: (UUID, Int))? {
        let selection = selectedRange()
        guard let start = mapper.blockPosition(at: selection.location),
              let end = mapper.blockPosition(at: NSMaxRange(selection)) else { return nil }
        return ((document.blocks[start.index].id, start.offset), (document.blocks[end.index].id, end.offset))
    }

    private func restoreSelection(_ anchors: (start: (UUID, Int), end: (UUID, Int))?, fallbackBlock: Int) {
        func location(_ anchor: (UUID, Int)) -> Int? {
            guard let index = document.index(ofBlock: anchor.0) else { return nil }
            let length = (document.blocks[index].text.string as NSString).length
            return mapper.paragraphStart(ofBlockAt: index) + min(anchor.1, length)
        }
        let fallback = mapper.paragraphStart(ofBlockAt: max(0, fallbackBlock))
        let start = anchors.flatMap { location($0.start) } ?? fallback
        let end = max(start, anchors.flatMap { location($0.end) } ?? start)
        setSelectedRange(NSRange(location: start, length: end - start))
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges.map(keepingBeforeFinalNewline), affinity: affinity, stillSelecting: stillSelecting)
        guard !stillSelecting else { return }
        applyEmptyParagraphTypingAttributes()
        updateEmptyParagraphHint()
        selectionDidChangeForPopups()
    }

    /// Выделение не заходит за последний перевод строки: строка после него — не блок.
    private func keepingBeforeFinalNewline(_ value: NSValue) -> NSValue {
        let last = max(0, (textStorage?.length ?? 0) - 1)
        let range = value.rangeValue
        guard NSMaxRange(range) > last else { return value }
        let location = min(range.location, last)
        return NSValue(range: NSRange(location: location, length: last - location))
    }

    /// В пустом абзаце набор идёт видом его блока, а не блока выше, с перевода строки которого начат абзац.
    private func applyEmptyParagraphTypingAttributes() {
        let selection = selectedRange()
        guard selection.length == 0, isAtEmptyParagraph(selection.location),
              let position = mapper.blockPosition(at: selection.location) else { return }
        typingAttributes = PageTextStorageMapper.typingAttributes(for: document.blocks[position.index])
    }

    private func isAtEmptyParagraph(_ location: Int) -> Bool {
        let string = (textStorage?.string ?? "") as NSString
        guard location < string.length else { return false }
        let atParagraphStart = location == 0 || string.character(at: location - 1) == 0x0A
        return atParagraphStart && string.character(at: location) == 0x0A
    }

    // MARK: Мышь

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = checkbox(at: point) {
            toggleCheckbox(ofBlock: id)
            return
        }
        if let pageId = linkedPage(at: point) {
            onOpenPage?(pageId)
            return
        }
        if openLink(at: point, modifiers: event.modifierFlags) { return }
        closePopups()
        super.mouseDown(with: event)
    }

    // MARK: Подсказка в пустом абзаце

    public override func becomeFirstResponder() -> Bool {
        defer {
            updateEmptyParagraphHint()
            updateSpellingMarks()
        }
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        defer {
            emptyParagraphHint.isHidden = true
            emptyHintBlockID = nil
            closePopups()
            updateSpellingMarks(isFocused: false)
        }
        return super.resignFirstResponder()
    }

    // MARK: Отметки орфографии

    /// Красные подчёркивания — только пока в тексте курсор и окно ключевое, как в Notion:
    /// в неактивном окне и при курсоре в названии их не видно. Выбор в меню «Правописание» сохраняется.
    private func updateSpellingMarks(isFocused: Bool? = nil) {
        let focused = isFocused ?? (window?.firstResponder === self)
        let active = spellCheckingWanted && window?.isKeyWindow == true && focused
        if isContinuousSpellCheckingEnabled != active { super.isContinuousSpellCheckingEnabled = active }
    }

    public override func toggleContinuousSpellChecking(_ sender: Any?) {
        spellCheckingWanted.toggle()
        super.isContinuousSpellCheckingEnabled = spellCheckingWanted
        updateSpellingMarks()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            if let window { NotificationCenter.default.removeObserver(self, name: name, object: window) }
            if let newWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(windowKeyStateDidChange(_:)), name: name, object: newWindow)
            }
        }
    }

    @objc private func windowKeyStateDidChange(_ notification: Notification) {
        updateSpellingMarks()
    }

    /// Подсказка у курсора в пустом блоке: своя для каждого типа (contracts/visual-style.md, «Пустые строки»).
    func updateEmptyParagraphHint() {
        let selection = selectedRange()
        guard window?.firstResponder === self, selection.length == 0, !hasMarkedText(), let window,
              let position = mapper.blockPosition(at: selection.location),
              let hint = isBareSlashLine(caret: selection.location, blockAt: position.index)
                ? Self.slashQueryHint
                : isAtEmptyParagraph(selection.location) ? Self.emptyBlockHint(for: document.blocks[position.index].kind) : nil else {
            emptyParagraphHint.isHidden = true
            emptyHintBlockID = nil
            return
        }
        emptyParagraphHint.stringValue = hint
        emptyHintBlockID = document.blocks[position.index].id
        let caretOnScreen = firstRect(forCharacterRange: selection, actualRange: nil)
        let caret = convert(window.convertFromScreen(caretOnScreen), from: nil)
        let font = typingAttributes[.font] as? NSFont ?? Typography.line(for: .paragraph).font
        emptyParagraphHint.font = font
        emptyParagraphHint.sizeToFit()
        // Подсказка стоит там, где встанет набранный текст: на базовой линии строки блока.
        let baseline = markerLine(ofBlockAt: position.index).map { $0.baseline + textContainerOrigin.y } ?? caret.maxY
        let size = emptyParagraphHint.frame.size
        emptyParagraphHint.frame = NSRect(x: caret.minX + Metrics.Page.emptyHintCaretGap, y: baseline - emptyParagraphHint.firstBaselineOffsetFromTop,
                                          width: size.width, height: size.height)
        emptyParagraphHint.isHidden = false
    }

    /// Подсветка «/» с набранным поиском, пока открыто меню «/» (координаты окна текста).
    var slashQueryHighlightFrame: NSRect? { slashQueryHighlight.isHidden ? nil : slashQueryHighlight.frame }

    static func emptyBlockHint(for kind: BlockKind) -> String? {
        switch kind {
        case .paragraph: "Введите «/» для выбора блока"
        case .bulletItem, .numberedItem: "Список"
        case .checkbox: "Задача"
        case .heading1: "Заголовок 1"
        case .heading2: "Заголовок 2"
        case .heading3: "Заголовок 3"
        case .pageLink: nil
        }
    }

    // MARK: Колонка и шапка

    /// Поля по бокам: колонка 720 по центру, в узком окне — не меньше `minimumSideInset`.
    private var sideInset: CGFloat {
        max(Metrics.Page.minimumSideInset, (bounds.width - Metrics.Page.columnWidth) / 2)
    }

    public override var textContainerOrigin: NSPoint {
        NSPoint(x: sideInset, y: header.frame.maxY)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { layoutColumn() }
    }

    private func layoutColumn() {
        let columnWidth = max(0, bounds.width - 2 * sideInset)
        let headerHeight = header.height(forWidth: columnWidth)
        header.frame = NSRect(x: sideInset, y: 0, width: columnWidth, height: headerHeight)
        // Отступ текста сверху — шапка, снизу — пустое место; NSTextView делит высоту поровну, а начало текста
        // задаёт `textContainerOrigin`.
        let inset = NSSize(width: sideInset, height: (headerHeight + Metrics.Page.bottomPadding) / 2)
        if textContainerInset != inset {
            textContainerInset = inset
        }
        invalidateTextContainerOrigin()
        updateEmptyParagraphHint()
    }

    // MARK: Фокус

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let focus = pendingFocus else { return }
        pendingFocus = nil
        // Следующий оборот цикла событий: окно уже на экране и принимает ввод.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch focus {
            case .title: header.focusTitle()
            case .body: focusBody(at: 0)
            }
            onReady?()
        }
    }

    public func focusBody(at location: Int) {
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: min(location, textStorage?.length ?? 0), length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// Записать текущий набор с IME и передать документу всё, что ещё не передано.
    public func commitEdits() {
        if hasMarkedText() { unmarkText() }
        mapper.commitPendingEdits()
    }
}

/// Шапка страницы над текстом: эмодзи-иконка и название (contracts/visual-style.md, «Страница»).
@MainActor
/// Поле названия: курсор того же цвета, что в блоках, а не системный синий.
final class PageTitleField: NSTextField {
    override class var cellClass: AnyClass? {
        get { PageTitleFieldCell.self }
        set {}
    }
}

private final class PageTitleFieldCell: NSTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        (editor as? NSTextView)?.insertionPointColor = Palette.textPrimary
        return editor
    }
}

public final class PageHeaderView: NSView, NSTextFieldDelegate {
    private let iconLabel = NSTextField(labelWithString: "")
    let titleField = PageTitleField(string: "")
    var onTitleChange: ((String) -> Void)?
    var onTitleEnter: (() -> Void)?

    init(page: Page) {
        super.init(frame: .zero)
        iconLabel.stringValue = page.icon ?? ""
        iconLabel.font = .systemFont(ofSize: Metrics.Page.iconFontSize)
        iconLabel.alignment = .center
        iconLabel.isHidden = page.icon == nil
        addSubview(iconLabel)

        let titleStyle = Typography.pageTitle
        titleField.stringValue = page.title
        titleField.font = titleStyle.font
        titleField.textColor = Palette.textPrimary
        let placeholderStyle = NSMutableParagraphStyle()
        placeholderStyle.firstLineHeadIndent = Metrics.Page.emptyHintCaretGap
        titleField.placeholderAttributedString = NSAttributedString(string: Page.untitledTitle, attributes: [
            .font: titleStyle.font, .foregroundColor: Palette.textSecondary, .paragraphStyle: placeholderStyle,
        ])
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.usesSingleLineMode = false
        titleField.cell?.wraps = true
        titleField.cell?.isScrollable = false
        titleField.lineBreakMode = .byWordWrapping
        titleField.maximumNumberOfLines = 0
        titleField.delegate = self
        titleField.setAccessibilityIdentifier("page-title")
        addSubview(titleField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public override var isFlipped: Bool { true }

    private var hasIcon: Bool { !iconLabel.isHidden }

    private var titleTop: CGFloat {
        hasIcon
            ? Metrics.Page.headerTopPadding + Metrics.Page.iconSize + Metrics.Page.iconToTitleSpacing
            : Metrics.Page.headerTopPaddingWithoutIcon
    }

    private func titleHeight(forWidth width: CGFloat) -> CGFloat {
        let fitting = titleField.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
        return max(fitting ?? 0, Typography.pageTitle.lineHeight)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        titleTop + titleHeight(forWidth: width) + Metrics.Page.titleToFirstBlockSpacing
    }

    public override func layout() {
        super.layout()
        // Строка эмодзи выше и шире квадрата иконки, хотя рисунок в нём помещается: поле по размеру строки
        // с серединой в середине квадрата, иначе рисунок обрезается или съезжает.
        let square = NSRect(x: 0, y: Metrics.Page.headerTopPadding, width: Metrics.Page.iconSize, height: Metrics.Page.iconSize)
        let line = iconLabel.intrinsicContentSize
        iconLabel.frame = NSRect(x: square.midX - line.width / 2, y: square.midY - line.height / 2, width: line.width, height: line.height)
        titleField.frame = NSRect(x: 0, y: titleTop, width: bounds.width, height: titleHeight(forWidth: bounds.width))
    }

    func focusTitle() {
        window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectedRange = NSRange(location: (titleField.stringValue as NSString).length, length: 0)
    }

    public func controlTextDidChange(_ notification: Notification) {
        onTitleChange?(titleField.stringValue)
        needsLayout = true
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Enter из названия — в первый блок (contracts/editor-interactions.md, ⌘N).
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        onTitleEnter?()
        return true
    }
}
