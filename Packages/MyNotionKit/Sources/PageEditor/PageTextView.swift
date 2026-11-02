import AppKit
import EmojiPicker
import NotesCore
import VisualStyle

/// Текст страницы (FR-013, research R2): один `NSTextView` на TextKit 2, абзац = блок.
/// Системное поведение текста — выделение, ⌘Z, проверка орфографии, ввод с IME, ⌘F — от `NSTextView`;
/// правки уходят в `PageDocument` через `PageTextStorageMapper`. Над текстом — шапка с иконкой и названием.
@MainActor
public class PageTextView: NSTextView, FollowsMistakeUnderlining {
    /// Блоки, которые правит этот редактор: поток страницы, колонки или ячейка таблицы (`FlowDocument`).
    public let document: FlowDocument
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
    /// Красные подчёркивания: «Подчёркивать ошибки» в Настройках и «Правописание → Проверять при вводе» у этой страницы.
    private(set) var spellCheckingWanted = MistakeUnderlining.isEnabled
    /// Шаблоны, которые предлагает пустая страница (US7), и что делать при выборе; строки появляются, только когда они нужны.
    var templateChoices: [TemplateChoice] = [] {
        didSet { if templateChoices != oldValue { updateTemplateRows() } }
    }
    var onChooseTemplate: (@MainActor (UUID) -> Void)?
    var templateRows: TemplateRowsController?
    /// Подложка под «/» с поиском, пока открыто меню «/».
    let slashQueryHighlight = NSView()

    /// Куда поставить курсор, когда страница появится в окне. `unchanged` — фокус остаётся, где был:
    /// страницу открыли из дерева, и стрелки, Enter и ⌘⌫ дальше работают в дереве.
    /// `bodyWithoutCaret` — страницу показали «назад/вперёд» или сменой вкладки: фокус в тексте, а курсора нет,
    /// пока человек сам не щёлкнет или не нажмёт клавишу, как в Notion.
    public enum InitialFocus { case title, body, bodyWithoutCaret, unchanged }
    private var pendingFocus: InitialFocus?
    /// Место прокрутки вкладки, на которое встать при показе (US3); возвращается до первой отрисовки.
    var pendingScrollPlace: TabScroll?
    private var didRestoreScrollPlace = false
    /// Возвращённое место держится, пока раскладка выше него уточняется (`keepScrollAnchor`).
    var scrollAnchor: ScrollAnchor?
    /// Страницу открыли «назад/вперёд» или сменой вкладки: курсора нет, пока человек сам не щёлкнет или не нажмёт клавишу, как в Notion.
    var isCaretHiddenUntilUserAction = false
    var isKeepingScrollAnchor = false
    /// Страница показана и принимает ввод.
    public var onReady: (@MainActor () -> Void)?
    /// Отмена, когда окна нет или оно своей не даёт (проверки без приложения).
    public var fallbackUndoManager: UndoManager?
    /// Пустой абзац, который поставил щелчок ниже последнего блока, пока в нём ничего не меняли (`TrailingParagraphClick`).
    var untouchedClickedParagraph: UUID?
    /// ⌘Z только что убрал такой абзац: отмена идёт дальше, к прежнему действию.
    var undoesPastClickedParagraph = false
    /// Названия и иконки страниц, на которые ссылаются блоки-подстраницы.
    public var linkedPages: [UUID: LinkedPage] = [:] {
        didSet { if linkedPages != oldValue { redrawBlockDecorations() } }
    }
    /// Юрий выбрал версию в «Двух версиях»: хозяин снимает конфликт в базе (`NotesTransaction.resolveConflict`)
    /// и отдаёт документу новый список (`PageDocument.replacePendingConflicts`).
    public var onResolveConflict: (@MainActor (Conflict) -> Void)?
    /// Метки «Две версии» у блоков в конфликте.
    private(set) lazy var conflictMarks = ConflictMarksOverlay(textView: self)
    /// Щелчок по блоку-подстранице: открыть страницу.
    public var onOpenPage: (@MainActor (UUID) -> Void)?
    /// Пункты страницы в меню блока-ссылки по правой кнопке (`PageLinkMenu.swift`): их даёт хозяин окна; `nil` —
    /// в меню только строки меню блока.
    public var pageLinkMenuEntries: (@MainActor (PageLinkMenuRequest) -> [ActionMenuEntry])?
    /// Меню блока-ссылки по правой кнопке.
    private(set) lazy var pageLinkMenu: PageLinkMenuPresenter = {
        let menu = PageLinkMenuPresenter()
        menu.textView = self
        return menu
    }()
    /// «Страница» в меню «/» и «Преобразовать в»: подстраницу со ссылкой у блока создаёт владелец дерева.
    public var onSubpageRequest: (@MainActor (SubpageRequest) -> Void)?
    /// ⌘-щелчок по ссылке: открыть адрес (по умолчанию — в браузере по умолчанию).
    public var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Разбор текста другой программы в блоки при ⌘V (Markdown ответа ИИ). Разбор Markdown живёт вне редактора:
    /// приложение ставит его при запуске в `defaultPastedTextReader`; `nil` — вставка текстом, как раньше.
    public static var defaultPastedTextReader: PastedTextReader?
    public var pastedTextReader: PastedTextReader? = PageTextView.defaultPastedTextReader
    /// Markdown и HTML скопированных блоков для других программ; пишет их тоже приложение. `nil` — простой текст.
    public static var defaultCopiedBlocksWriter: CopiedBlocksWriter?
    public var copiedBlocksWriter: CopiedBlocksWriter? = PageTextView.defaultCopiedBlocksWriter
    let layoutDelegate = BlockLayoutDelegate()
    /// Виды колонок и таблиц в тексте и их высоты (`Flows/`).
    let embeddedViews = EmbeddedBlockViews()
    /// ⌘F по всей странице; у редакторов колонок и ячеек — не используется, поиск у страницы (`PageFind/`).
    private(set) lazy var pageFind = PageFind(root: self)
    /// Абзацы детей свёрнутых переключателей: не раскладываются (research R1).
    let hiddenParagraphs = HiddenParagraphs()
    /// Свёрнутые переключатели этого Mac и отступы по поддеревьям (`Collapsing/`).
    let collapsedParagraphs = CollapsedParagraphs()
    let popups = EditorPopupController()
    /// Вставка картинок, файлов, видео и закладок: меню вставленной ссылки, окно «Выбрать файл…» (US5).
    let mediaInsertion = MediaInsertionState()
    /// Упоминания, даты и окно «@» (US3).
    let inlineAtoms = InlineAtomsState()
    /// Виды блоков кода страницы и курсор между ними и текстом (US4).
    let codeBlocks = CodeBlockRegistry()
    /// Окно правки формулы (US4). Создаётся при первом открытии: его виды стоили бы каждому открытию страницы 1,5 мс.
    private(set) lazy var equationEditor: EquationEditorController = {
        let editor = EquationEditorController()
        editor.textView = self
        return editor
    }()
    /// Виды оглавлений и слежение за заголовками (US4).
    let tableOfContentsViews = TableOfContentsViews()
    private(set) var tableOfContentsTracker: TableOfContentsTracker?
    /// Виды блоков без своего текста на экране: их ставит страница, TextKit 2 этого не делает (US4).
    private(set) lazy var blockViews = BlockViewHosting(textView: self)
    let formatBar = FormatBarController()
    /// «Исправить ошибки»: окно правок под выделением.
    let proofreading = ProofreadController()
    /// Последние цвета текста и фона: окно цветов и ⌘⇧H.
    var recentColors = RecentColors()
    let colorMenu = ColorMenuController()
    /// Иконку выбрали в шапке (FR-034): «Добавить иконку», окно выбора; `nil` — убрать. Хозяин сохраняет её
    /// и возвращает через `showIcon`.
    public var onSetIcon: ((String?) -> Void)?
    let iconPicker = EmojiPickerController()
    /// Где указатель мыши на экране; тесты подменяют.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    lazy var blockHandles = BlockHandlesOverlay(textView: self)
    /// Курсор как в Notion вместо системного (`TextCaret`).
    private(set) lazy var caret = TextCaret(textView: self)
    /// Полосы выделения, нарисованные в последний раз: их место перерисовывается при смене выделения.
    private(set) var drawnSelectionRects: [NSRect] = []
    /// Нарисованы подложки блоков целиком, а не полосы по тексту.
    private var drawnSelectionIsBlocks = false
    /// Режим выделения блоков (`BlockSelectionMode`): опорный блок и подвижный край; `nil` — обычное выделение.
    var blockSelectionEnds: (anchor: Int, head: Int)?
    /// Выделение меняет сам режим блоков — режим не снимается.
    var isApplyingBlockSelection = false
    private(set) var isPerformingCommand = false
    /// Текст страницы загружается в редактор: выделение меняет сама загрузка.
    private var isLoadingText = false
    /// Протяжка мышью с поля: где нажали и сдвинулась ли мышь.
    var marginDrag: (start: NSPoint, moved: Bool)?
    /// Вид страницы: ширина колонки и шкала шрифтов (`PageLayout/`).
    public internal(set) var layoutSettings = PageLayoutSettings()
    /// Место обложки над шапкой (`PageLayout/`).
    let coverSlot = CoverSlot()
    /// Добавки шапки от хозяина редактора (US1: обложка); живут, пока жив редактор.
    public internal(set) var headerAddons: [any PageHeaderAddon] = []

    public convenience init(document: PageDocument, initialFocus: InitialFocus) {
        self.init(flow: FlowDocument(document), initialFocus: initialFocus)
    }

    init(flow document: FlowDocument, initialFocus: InitialFocus) {
        self.document = document
        header = PageHeaderView(page: document.page)
        pendingFocus = initialFocus

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: Metrics.Page.columnWidth, height: .greatestFiniteMagnitude))
        // Ширину колонки задаёт `layoutColumn`: поля слева и справа бывают разными.
        container.widthTracksTextView = false
        container.lineFragmentPadding = Metrics.Page.blockHorizontalPadding
        layoutManager.textContainer = container
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.Page.columnWidth, height: 0), textContainer: container)
        layoutDelegate.textView = self
        layoutManager.delegate = layoutDelegate
        hiddenParagraphs.textView = self
        contentStorage.delegate = hiddenParagraphs
        collapsedParagraphs.textView = self
        popups.textView = self
        formatBar.textView = self
        proofreading.textView = self
        colorMenu.textView = self

        configureTextBehaviour()
        BuiltInBlockViews.registerOnce()
        tableOfContentsTracker = TableOfContentsTracker(textView: self)
        mapper = PageTextStorageMapper(flow: document, textStorage: textStorage!)
        // Вид страницы — до загрузки текста: страница с мелким шрифтом сразу пишется мелкой.
        layoutSettings = PageLayoutSettings(isFullWidth: document.page.isFullWidth, isSmallText: document.page.isSmallText)
        mapper.fontScale = layoutSettings.fontScale
        coverSlot.shownAppearance = PageAppearance(document.page)
        // После загрузки текста система ставит выделение в конец, и место курсора там считалось бы раскладкой
        // всей страницы (на 10 000 блоках — секунды). Пока текст загружается, вид выделения не обновляется;
        // курсор — в начало, куда его потом и ставит открытие страницы.
        isLoadingText = true
        mapper.load()
        refreshBlockStructure()
        isLoadingText = false
        setSelectedRange(NSRange(location: 0, length: 0))
        // Отмена правки текста не зовёт didChangeText: забрать её в документ сразу после ⌘Z и ⇧⌘Z.
        for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoManagerDidRestore(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(documentDidApplyExternalChanges(_:)),
                                               name: PageDocument.didApplyExternalChanges, object: document.pageDocument)
        NotificationCenter.default.addObserver(self, selector: #selector(documentDidApplyLocalEdits(_:)),
                                               name: PageDocument.didApplyLocalEdits, object: document.pageDocument)
        NotificationCenter.default.addObserver(self, selector: #selector(blockViewStateDidChangeOutsideEditor(_:)),
                                               name: BlockViewStateStore.didChangeOutsideEditor, object: nil)
        Self.liveEditors.add(self)

        addSubview(header)
        slashQueryHighlight.wantsLayer = true
        slashQueryHighlight.layer?.cornerRadius = Metrics.PopupMenu.slashQueryCornerRadius
        slashQueryHighlight.isHidden = true
        addSubview(slashQueryHighlight)
        addSubview(emptyParagraphHint)
        emptyParagraphHint.textColor = Palette.textSecondary
        emptyParagraphHint.isHidden = true
        header.onTitleChange = { [weak self] title in
            self?.document.setTitle(title, origin: self?.textStorage)
            self?.layoutColumn()
        }
        header.onTitleEnter = { [weak self] in self?.focusBody(at: 0) }
        header.onAddIcon = { [weak self] in
            var generator = SystemRandomNumberGenerator()
            self?.onSetIcon?(EmojiCatalog.shared.random(using: &generator).character)
        }
        header.onIconClick = { [weak self] in self?.openIconPicker() }
        _ = caret
        layoutColumn()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    private func configureTextBehaviour() {
        isRichText = true
        importsGraphics = false
        allowsUndo = true
        // ⌘F — одна полоса поиска на всю страницу, с колонками и ячейками (`PageFind/`), а не поиск этого текста.
        usesFindBar = false
        isIncrementalSearchingEnabled = false
        isContinuousSpellCheckingEnabled = spellCheckingWanted
        isGrammarCheckingEnabled = false
        isAutomaticSpellingCorrectionEnabled = MistakeUnderlining.correctsSpellingAutomatically
        NotificationCenter.default.addObserver(self, selector: #selector(mistakeUnderliningDidChange), name: MistakeUnderlining.didChange, object: nil)
        drawsBackground = true
        backgroundColor = Palette.pageBackground
        // Курсор и выделение рисует сам редактор, как в Notion: системные — на всю строку и красят текст в белый.
        insertionPointColor = .clear
        selectedTextAttributes = [:]
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
        guard let undoManager, notification.object as? UndoManager === undoManager else { return }
        if undoesPastClickedParagraph, notification.name == .NSUndoManagerDidUndoChange {
            undoesPastClickedParagraph = false
            if undoManager.canUndo { undoManager.undo() }
        }
        guard mapper.hasPendingEdits else { return }
        let blockCount = document.blocks.count
        mapper.commitPendingEdits()
        refreshBlockStructure()
        if document.blocks.count != blockCount { redrawBlockDecorations() }
        updateEmptyParagraphHint()
    }

    /// Правка с другого Mac легла в документ (research R5): перерисовать затронутые блоки, курсор оставить
    /// в своём блоке на том же месте. Прежние шаги ⌘Z относятся к старому тексту — их больше нет.
    @objc private func documentDidApplyExternalChanges(_ notification: Notification) {
        guard let change = notification.userInfo?[PageDocument.externalChangeKey] as? PageDocument.ExternalChange else { return }
        render(change, keepsUndo: false)
    }

    /// Ту же страницу правят в другом окне (FR-029): показать их правку так же, как пришедшую с другого Mac.
    /// Свою правку этот редактор уже показывает — её он не перерисовывает, и его ⌘Z цела.
    @objc private func documentDidApplyLocalEdits(_ notification: Notification) {
        let origin = notification.userInfo?[PageDocument.editOriginKey] as? ObjectIdentifier
        guard let change = notification.userInfo?[PageDocument.externalChangeKey] as? PageDocument.ExternalChange,
              let textStorage, origin != ObjectIdentifier(textStorage)
        else { return }
        render(change, keepsUndo: sharesUndo(withEditOrigin: origin))
    }

    /// `keepsUndo` — правку сделал редактор с той же отменой (колонка, ячейка, этот же редактор через документ):
    /// её шаг лежит в общей отмене окна, и прежние шаги остаются верны.
    private func render(_ change: PageDocument.ExternalChange, keepsUndo: Bool) {
        // Правка чужого потока (колонки, ячейки) этот текст не трогает.
        if change.touchesBlocks, !change.changedFlowIds.contains(document.flowKey),
           !change.changedBlockIds.contains(where: { document.index(ofBlock: $0) != nil }) {
            if change.conflictsChanged { conflictMarks.update() }
            return
        }
        if change.titleChanged, header.titleField.currentEditor() == nil {
            header.titleField.stringValue = document.page.title
            layoutColumn()
        }
        if change.iconChanged { showIcon(document.page.icon) }
        if change.touchesBlocks {
            let anchors = selectionAnchors()
            mapper.renderExternalChanges(change)
            refreshBlockStructure()
            if !keepsUndo { undoManager?.removeAllActions() }
            restoreSelection(anchors, fallbackBlock: 0)
            redrawBlockDecorations()
            updateEmptyParagraphHint()
        }
        if change.touchesBlocks || change.conflictsChanged { conflictMarks.update() }
    }

    public override func didChangeText() {
        scrollAnchor = nil
        untouchedClickedParagraph = nil
        super.didChangeText()
        // Посреди набора с помощью IME текст ещё не окончательный.
        guard !hasMarkedText() else { return }
        let blockCount = document.blocks.count
        mapper.commitPendingEdits()
        if document.blocks.count != blockCount {
            refreshBlockStructure()
            redrawBlockDecorations()
        } else if let position = mapper.blockPosition(at: selectedRange().location) {
            // Набор внутри блока: поддеревья те же, поправки нужны только перерисованным абзацам.
            reapplyAdjustments(aroundBlockAt: position.index)
        }
        // После удаления выделения AppKit оставляет оформление его первого знака (например, заголовка),
        // а курсор уже в пустом абзаце.
        applyEmptyParagraphTypingAttributes()
        updateEmptyParagraphHint()
        textDidChangeForPopups()
        refreshMentionPicker()
        updateSelectionLook()
        if !document.pendingConflicts.isEmpty { conflictMarks.update() }
        blockViews.update()
    }

    /// Вставка: адрес поверх выделения — ссылка, текст других программ — с поддерживаемым оформлением.
    public override func paste(_ sender: Any?) {
        paste(from: .general)
    }

    public override func pasteAsRichText(_ sender: Any?) {
        paste(from: .general)
    }

    /// «Вставить без форматирования» (⌥⇧⌘V): простой текст, без разбора Markdown и оформления.
    public override func pasteAsPlainText(_ sender: Any?) {
        paste(from: .general, asPlainText: true)
    }

    /// Копирование: несколько блоков — своим типом, Markdown и HTML (`CopiedBlocks`); в простом тексте части блока
    /// перенос строки внутри блока — обычный перевод строки.
    public override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        // NSTextView объявляет простой текст старым именем — это тот же тип.
        let type = type == Self.legacyStringPasteboardType ? .string : type
        if type == Self.inlineTextPasteboardType { return writeInlineText(to: pboard) }
        if type == Self.blocksPasteboardType || type == .string || type == .html, writeCopiedBlocks(to: pboard, type: type) { return true }
        if type == Self.blocksPasteboardType || type == .html { return false }
        guard type == .string else { return super.writeSelection(to: pboard, type: type) }
        let text = selectedRanges.map { plainText(of: $0.rangeValue) }.joined(separator: "\n")
        guard !text.isEmpty else { return false }
        return pboard.setString(PageTextStorageMapper.blockString(ofPageText: text), forType: .string)
    }

    private static let legacyStringPasteboardType = NSPasteboard.PasteboardType("NSStringPboardType")

    public override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.blocksPasteboardType, Self.inlineTextPasteboardType, .html] + super.writablePasteboardTypes.filter { $0 != .html }
    }

    public override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        // Объявленный тип без данных чужая программа берёт пустым: свой тип и HTML — только для нескольких блоков.
        let writesBlocks = copiedBlocks() != nil
        let types = types.filter { type in
            type == Self.blocksPasteboardType ? writesBlocks : type == .html ? writesBlocks && copiedBlocksWriter != nil : true
        }
        pboard.declareTypes(types, owner: nil)
        return types.map { writeSelection(to: pboard, type: $0) }.contains(true)
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        // В режиме блоков набор букв блоки не заменяет, как в Notion.
        if isBlockSelection, replacementRange.location == NSNotFound, !hasMarkedText() { return }
        hideBlockHandles()
        if allowsBlockStructure, typed == " ", replacementRange.location == NSNotFound, !hasMarkedText(), applyMarkdownShortcut() { return }
        if allowsBlockStructure, typed == "-", replacementRange.location == NSNotFound, !hasMarkedText(), isCaretAfterTwoDashes {
            super.insertText(string, replacementRange: replacementRange)
            convertDashesToDivider()
            return
        }
        if typed == "`", replacementRange.location == NSNotFound, !hasMarkedText(), isCaretAfterTwoBackticks {
            super.insertText(string, replacementRange: replacementRange)
            convertBackticksToCode()
            return
        }
        if replacementRange.location == NSNotFound, !hasMarkedText(), !typed.isEmpty, !typed.hasPrefix("\n"), isCaretInPageLink {
            // В блоке-подстранице текста нет: набранное уходит в новый абзац под ним.
            super.insertText("\n" + typed, replacementRange: replacementRange)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
        if allowsBlockStructure, typed == "/" { openSlashMenuAfterTypedSlash() }
        openMentionPicker(afterTyping: typed)
    }

    /// Курсор стоит в блоке-подстранице (у него свой абзац без символов).
    var isCaretInPageLink: Bool {
        let selection = selectedRange()
        guard selection.length == 0, let position = mapper.blockPosition(at: selection.location) else { return false }
        return document.blocks[position.index].kind == .pageLink
    }

    /// В режиме блоков набор через способ ввода блоки тоже не заменяет.
    public override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !isBlockSelection else { return }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    public override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText(), handleBackspaceUnderCollapsedToggle() || handleBackspaceAtContainerStart() || handleBackspaceAtBlockStart() {
            return
        }
        super.deleteBackward(sender)
    }

    /// ⌦ в конце блока перед блоком без текста не склеивает их, а выделяет тот блок. В конце свёрнутого переключателя
    /// или заголовка спрятанное не трогается: соседом считается первый видимый блок после него.
    public override func deleteForward(_ sender: Any?) {
        let selection = selectedRange()
        if !hasMarkedText(), selection.length == 0, let position = mapper.blockPosition(at: selection.location),
           position.offset == document.blocks[position.index].pageTextLength {
            let next = endIncludingHidden(ofBlockAt: position.index)
            // Пустой абзац перед блоком без текста (ссылка, картинка…) просто убирается; следующий блок выделяется,
            // курсор в него не попадает.
            if next == position.index + 1, next < document.blocks.count, document.blocks[position.index].kind == .paragraph,
               document.blocks[position.index].text.string.isEmpty,
               document.blocks[next].kind.rendersAsAttachment || document.blocks[next].kind == .pageLink {
                removeBlocks(at: position.index..<next)
                selectBlocks(position.index..<position.index + 1)
                return
            }
            if next < document.blocks.count, document.blocks[next].kind.rendersAsAttachment {
                selectBlocks(next..<next + 1)
                return
            }
            if next > position.index + 1 {
                // Абзац после спрятанного склеивается с владельцем, как ⌫ в его начале; другие блоки ⌦ не тянет.
                if next < document.blocks.count, document.blocks[next].kind == .paragraph {
                    setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: next), length: 0))
                    if !handleBackspaceUnderCollapsedToggle() { setSelectedRange(selection) }
                }
                return
            }
        }
        super.deleteForward(sender)
    }

    public override func insertNewline(_ sender: Any?) {
        if !hasMarkedText(), handleNewlineInContainer() || handleNewlineInCollapsedHeading() || handleNewlineInEmptyChild() || handleNewlineInEmptyItem() { return }
        super.insertNewline(sender)
    }

    /// Shift+Enter — перенос строки внутри блока (FR-032). В блоке-подстранице текста нет: как Enter.
    public override func insertLineBreak(_ sender: Any?) {
        guard !isCaretInPageLink else {
            insertNewline(sender)
            return
        }
        insertText(PageTextStorageMapper.lineSeparatorString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    public override func insertTab(_ sender: Any?) { perform(.indent) }
    public override func insertBacktab(_ sender: Any?) { perform(.outdent) }
    public override func moveParagraphBackwardAndModifySelection(_ sender: Any?) { perform(.moveBlocksUp) }
    public override func moveParagraphForwardAndModifySelection(_ sender: Any?) { perform(.moveBlocksDown) }

    public override func keyDown(with event: NSEvent) {
        revealCaretAfterReturn()
        hideBlockHandles()
        if !hasMarkedText(), let command = EditorKeyBindings.command(for: event), handlesKey(command) {
            perform(command)
            return
        }
        // С открытым меню «/» Shift+Enter выбирает пункт, как Enter.
        if !hasMarkedText(), !popups.isOpen, EditorKeyBindings.isLineBreak(event) {
            insertLineBreak(nil)
            return
        }
        super.keyDown(with: event)
    }

    /// ⌘B, ⌘I, ⇧⌘X, ⌘E, ⌘Enter — раньше меню: окно спрашивает поле ввода первым.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, !hasMarkedText(), let command = EditorKeyBindings.command(for: event), handlesKey(command) {
            perform(command)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.cancelOperation(_:)), blockHandles.isDragging {
            blockHandles.cancelDrag()
            return
        }
        if handleTemplateRowsCommand(selector) { return }
        if handleMentionPickerCommand(selector) { return }
        if handlePopupCommand(selector) { return }
        if colorMenu.handleCommand(selector) { return }
        if proofreading.handleCommand(selector) { return }
        if formatBar.handleCommand(selector) { return }
        if handleBlockSelectionCommand(selector) { return }
        if handleArrowIntoCode(selector) { return }
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
           document.blocks[position.index].kind == .pageLink || document.blocks[position.index].kind.rendersAsAttachment {
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
        // Пока команда перестраивает текст, выделение на миг сходит на нет: панель форматирования
        // не прячем и не ставим заново — после команды она на прежнем месте (как в Notion).
        isPerformingCommand = true
        keepingBlockSelection { performOnSelectedBlocks(command) }
        isPerformingCommand = false
        updateFormatBar()
    }

    private func performOnSelectedBlocks(_ command: EditorCommand) {
        switch command {
        case .indent: indentSelectedBlocks(by: 1)
        case .outdent: indentSelectedBlocks(by: -1)
        case .moveBlocksUp: moveSelectedBlocks(by: -1)
        case .moveBlocksDown: moveSelectedBlocks(by: 1)
        case .toggleChecked: toggleCheckedSelectedBlocks()
        case .toggleAllCollapsed: toggleAllCollapsed()
        case .toggleInline(let format): toggleInline(format)
        case .clearInlineFormatting: clearInlineFormatting()
        case .setKind(let kind):
            commitEdits()
            if let selected = selectedBlockRange() { setKind(kind, ofBlocksAt: selected) }
        case .applyColor(let choice): applyColor(choice)
        case .applyBlockColor(let choice): applyBlockColor(choice)
        case .repeatLastColor: repeatLastColor()
        case .insertInlineEquation: insertInlineEquation()
        case .duplicateBlocks:
            if let selected = selectedBlockRange() { duplicateBlocks(at: selected) }
        case .moveBlocksToPage:
            if let selected = selectedBlocks { requestMoveBlocks(selected, anchor: nil) }
        }
    }

    /// «Переместить в» (US4): окно выбирает страницу и переносит блоки (`PageTreeOperations.moveBlocks`).
    func requestMoveBlocks(_ range: Range<Int>, anchor: NSRect?) {
        commitEdits()
        guard !range.isEmpty, range.upperBound <= document.blocks.count else { return }
        onSubpageRequest?(.moveBlocks(blockIds: document.blocks[range].map(\.id), anchor: anchor))
    }

    /// ⇧⌘P берёт редактор, только когда выделены блоки; иначе клавиша — у меню окна (переносит страницу).
    private func handlesKey(_ command: EditorCommand) -> Bool {
        command != .moveBlocksToPage || isBlockSelection
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
        // Свёрнутый блок со спрятанным под ним — один блок.
        let single = endIncludingHidden(ofBlockAt: range.lowerBound) >= range.upperBound ? range.lowerBound..<range.lowerBound + 1 : range
        if kind == .pageLink { return turnIntoSubpage(blockAt: single) }
        if kind == .divider, single.count == 1 { return insertDivider(at: range.lowerBound) }
        if kind == .code, single.count == 1, document.blocks[range.lowerBound].kind != .code { return insertCode(at: range.lowerBound) }
        if kind == .equation, single.count == 1, document.blocks[range.lowerBound].kind != .equation {
            return insertEquation(at: range.lowerBound)
        }
        if kind == .tableOfContents, single.count == 1 { return insertTableOfContents(at: range.lowerBound) }
        if BlockKind.withAttachments.contains(kind) { return beginAttachmentInsertion(kind, at: range.lowerBound) }
        let blocks = document.blocks
        // Спрятанное в свёрнутом едет с выделением, но тип меняют только видимые блоки.
        let shown = range.filter { !hiddenParagraphs.isHidden(blocks[$0].id) }
        // Уже этого типа (⌥⌘2 по заголовку 2) — ничего не менять и не оставлять пустого шага отмены.
        if shown.allSatisfy({ blocks[$0].kind == kind }) { return }
        let drafts = range.map { index in
            let block = blocks[index]
            var draft = BlockDraft(block)
            guard shown.contains(index) else { return draft }
            draft.kind = kind
            if kind != .checkbox { draft.isChecked = false }
            if kind != block.kind { draft.adoptDefaults(of: kind, from: block) }
            // Заголовок вкладывается только внутрь переключателя, выноски, цитаты.
            if kind.isHeading { draft.indent = BlockMoveController.headingIndent(block.indent, at: index, in: blocks) }
            return draft
        }
        changeBlocks(range, to: drafts, actionName: "Тип блока")
    }

    /// «Преобразовать в → Страница», как в Notion: текстовый блок становится ссылкой на подстраницу с этим текстом
    /// в названии, вложенные под ним блоки переезжают внутрь (`PageTreeOperations.turnIntoSubpage`). Только один блок.
    private func turnIntoSubpage(blockAt range: Range<Int>) {
        guard range.count == 1, let index = range.first else { return }
        let block = document.blocks[index]
        guard block.kind != .pageLink, !block.kind.rendersAsAttachment, !block.kind.isContainer else { return }
        commitEdits()
        onSubpageRequest?(.turnInto(blockId: block.id))
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
        // Без чекбоксов ⌘Enter сворачивает и раскрывает переключатели.
        guard let first = checkboxes.first, let last = checkboxes.last else { return toggleCollapsedSelectedBlocks() }
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
        if let clicked = untouchedClickedParagraph, undoManager?.isUndoing == true,
           blocks[range].contains(where: { $0.id == clicked }) {
            undoesPastClickedParagraph = true
        }
        untouchedClickedParagraph = nil

        let anchors = selectionAnchors()
        let touchesEnd = range.upperBound == blocks.count
        let characters = mapper.characterRange(ofBlocksAt: range)

        let previousId = range.lowerBound > 0 ? blocks[range.lowerBound - 1].id : nil
        let nextId = touchesEnd ? nil : blocks[range.upperBound].id
        let ids = document.replaceBlocks(after: previousId, before: nextId, with: drafts, movedBlockIds: moved, origin: textStorage)
        let changed = range.lowerBound..<range.lowerBound + ids.count
        mapper.renderBlocks(changed, replacing: characters)
        refreshBlockStructure()

        restoreSelection(anchors, fallbackBlock: min(range.lowerBound, document.blocks.count - 1))
        redrawBlockDecorations()
        blockViews.update()
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
            let length = document.blocks[index].pageTextLength
            return mapper.paragraphStart(ofBlockAt: index) + min(anchor.1, length)
        }
        let fallback = mapper.paragraphStart(ofBlockAt: max(0, fallbackBlock))
        let start = anchors.flatMap { location($0.start) } ?? fallback
        let end = max(start, anchors.flatMap { location($0.end) } ?? start)
        setSelectedRange(NSRange(location: start, length: end - start))
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !isApplyingBlockSelection { blockSelectionEnds = nil }
        var ranges = ranges.map(keepingBeforeFinalNewline)
        // Курсор в абзац блока без текста не встаёт — перешагивает его (research R2).
        if ranges.count == 1, ranges[0].rangeValue.length == 0, !isLoadingText {
            let location = ranges[0].rangeValue.location
            let skipped = caretSkippingAttachments(location, from: selectedRange().location)
            if skipped != location { ranges = [NSValue(range: NSRange(location: skipped, length: 0))] }
        }
        // Курсор и выделение у детей свёрнутого переключателя (research R1).
        if ranges.count == 1, !isLoadingText {
            let adjusted = selectionRespectingCollapsed(ranges[0].rangeValue, from: selectedRange())
            if adjusted != ranges[0].rangeValue { ranges = [NSValue(range: adjusted)] }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !isLoadingText else { return }
        updateSelectionLook()
        proofreading.selectionDidChange(selectedRange())
        guard !stillSelecting else {
            formatBar.hide()
            return
        }
        applyEmptyParagraphTypingAttributes()
        updateEmptyParagraphHint()
        selectionDidChangeForPopups()
        refreshMentionPicker()
        updateFormatBar()
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
        typingAttributes = PageTextStorageMapper.typingAttributes(for: document.blocks[position.index],
                                                                 after: mapper.previousKind(ofBlockAt: position.index))
    }

    private func isAtEmptyParagraph(_ location: Int) -> Bool {
        let string = (textStorage?.string ?? "") as NSString
        guard location < string.length else { return false }
        let atParagraphStart = location == 0 || string.character(at: location - 1) == 0x0A
        return atParagraphStart && string.character(at: location) == 0x0A
    }

    func revealCaretAfterReturn() {
        guard isCaretHiddenUntilUserAction else { return }
        isCaretHiddenUntilUserAction = false
        caret.update()
    }

    // MARK: Мышь

    public override func mouseDown(with event: NSEvent) {
        revealCaretAfterReturn()
        let point = convert(event.locationInWindow, from: nil)
        if let id = checkbox(at: point) {
            toggleCheckbox(ofBlock: id)
            return
        }
        if handleStructuralBlockClick(at: point) { return }
        if isBelowLastBlock(point) {
            placeCaretInTrailingParagraph()
            return
        }
        if let pageId = linkedPage(at: point) {
            onOpenPage?(pageId)
            return
        }
        if openAtom(at: point) { return }
        if openLink(at: point, modifiers: event.modifierFlags) { return }
        if isMarginPoint(point) {
            beginMarginDrag(at: point)
            return
        }
        closePopups()
        super.mouseDown(with: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard marginDrag != nil else { return super.mouseDragged(with: event) }
        continueMarginDrag(event)
    }

    public override func mouseUp(with event: NSEvent) {
        guard marginDrag != nil else { return super.mouseUp(with: event) }
        endMarginDrag(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: Подсказка в пустом абзаце

    public override func becomeFirstResponder() -> Bool {
        defer {
            updateEmptyParagraphHint()
            updateSpellingMarks()
            updateSelectionLook()
        }
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        defer {
            emptyParagraphHint.isHidden = true
            emptyHintBlockID = nil
            closePopups()
            formatBar.hide()
            proofreading.cancel()
            updateSpellingMarks(isFocused: false)
            updateSelectionLook(isFocused: false)
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

    /// «Подчёркивать ошибки» переключили в Настройках: подчёркивания и автоисправление — сразу, без перезапуска.
    @objc private func mistakeUnderliningDidChange() {
        spellCheckingWanted = MistakeUnderlining.isEnabled
        isAutomaticSpellingCorrectionEnabled = MistakeUnderlining.correctsSpellingAutomatically
        updateSpellingMarks()
    }

    public override func toggleContinuousSpellChecking(_ sender: Any?) {
        spellCheckingWanted.toggle()
        super.isContinuousSpellCheckingEnabled = spellCheckingWanted
        updateSpellingMarks()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Страницу закрыли или сменили: её панель и меню не остаются висеть над окном.
        if newWindow == nil {
            formatBar.hide()
            closePopups()
            iconPicker.close()
            proofreading.cancel()
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            if let window { NotificationCenter.default.removeObserver(self, name: name, object: window) }
            if let newWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(windowKeyStateDidChange(_:)), name: name, object: newWindow)
            }
        }
    }

    @objc private func windowKeyStateDidChange(_ notification: Notification) {
        updateSpellingMarks()
        caret.update()
    }

    /// Подсказка у курсора в пустом блоке: своя для каждого типа (contracts/visual-style.md, «Пустые строки»).
    func updateEmptyParagraphHint() {
        updateEmptyParagraphHintLabel()
        updateTemplateRows()
    }

    private func updateEmptyParagraphHintLabel() {
        let selection = selectedRange()
        guard window?.firstResponder === self, selection.length == 0, !hasMarkedText(), let window,
              let position = mapper.blockPosition(at: selection.location) else {
            emptyParagraphHint.isHidden = true
            emptyHintBlockID = nil
            return
        }
        let isSlashLine = isBareSlashLine(caret: selection.location, blockAt: position.index)
        guard let hint = isSlashLine
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
        // Шрифт — по типу блока, а не из оформления набора: оно бывает от другого блока или с жирным.
        let kindFont = Typography.line(for: PageTextStorageMapper.textStyle(of: document.blocks[position.index].kind)).font
        let font = kindFont.withSize(kindFont.pointSize * layoutSettings.fontScale)
        emptyParagraphHint.font = font
        emptyParagraphHint.sizeToFit()
        // Подсказка стоит там, где встанет набранный текст: с начала текста блока, на базовой линии его строки.
        // Начало — по раскладке блока, а не по `firstRect`: у последнего блока страницы в одном фрагменте с ним
        // лежит пустая строка за финальным переводом строки, и `firstRect` теряет отступ пункта.
        let line = markerLine(ofBlockAt: position.index)
        let textStart = line.map { $0.caretX + textContainerOrigin.x } ?? caret.minX
        let baseline = line.map { $0.baseline + textContainerOrigin.y } ?? caret.maxY
        // «Начните вводить для поиска» — сразу за «/», с места курсора, как «Type to search» у Notion;
        // `firstRect` поправлен на тот же потерянный отступ.
        let blockStart = convert(window.convertFromScreen(firstRect(forCharacterRange: NSRange(location: selection.location - position.offset, length: 0),
                                                                    actualRange: nil)), from: nil)
        let x = (isSlashLine ? caret.minX + (textStart - blockStart.minX) : textStart) - Self.hintLabelTextInset
        let size = emptyParagraphHint.frame.size
        emptyParagraphHint.frame = NSRect(x: x, y: baseline - emptyParagraphHint.firstBaselineOffsetFromTop, width: size.width, height: size.height)
        emptyParagraphHint.isHidden = false
    }

    /// Подсветка «/» с набранным поиском, пока открыто меню «/» (координаты окна текста).
    var slashQueryHighlightFrame: NSRect? { slashQueryHighlight.isHidden ? nil : slashQueryHighlight.frame }

    static func emptyBlockHint(for kind: BlockKind) -> String? {
        kind.descriptor.emptyHint
    }

    // MARK: Колонка и шапка

    /// Колонка 720 по центру всей прокрутки, в узком окне — поля не меньше `minimumSideInset`.
    /// Центр — по ширине вместе с полосой прокрутки: длинная страница с полосой не сдвигается (раунд 2, № 23).
    /// У редактора колонки (`FlowTextView`) — вся его ширина.
    var column: (left: CGFloat, width: CGFloat) {
        layoutSettings.column(pageWidth: enclosingScrollView?.frame.width ?? bounds.width, textWidth: bounds.width)
    }

    /// Набор — в шкале шрифта страницы, откуда бы ни пришли атрибуты (описатель блока, оформление в строке).
    public override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set { super.typingAttributes = PageFontScaling.scaled(newValue, to: layoutSettings.fontScale) }
    }

    public override var textContainerOrigin: NSPoint {
        NSPoint(x: column.left, y: header.frame.maxY)
    }

    /// После раскладки видимой области — виды блоков на свои абзацы, возвращённое место прокрутки — на своё.
    public override func layout() {
        layoutKeepingScrollAnchor { super.layout() }
        blockViews.update()
        keepScrollAnchor()
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        blockViews.observeScrolling()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { layoutColumn() }
    }

    /// Показать иконку страницы из документа: шапка и текст сдвигаются, как при открытии страницы с ней.
    public func showIcon(_ icon: String?) {
        guard icon != header.iconView.emoji else { return }
        header.setIcon(icon)
        layoutColumn()
    }

    /// Окно выбора иконки под иконкой шапки, как у Notion.
    public func openIconPicker() {
        guard let window else { return }
        let icon = header.iconView
        let anchor = window.convertToScreen(icon.convert(icon.bounds, to: nil))
        iconPicker.show(below: anchor, in: window) { [weak self] in self?.onSetIcon?($0) }
    }

    /// Над текстом — шапка с иконкой и названием; у редакторов колонок и ячеек её нет.
    var showsPageHeader: Bool { true }
    /// Блоки можно делать и менять: меню «/», быстрые символы, «---». В ячейке таблицы — нельзя.
    var allowsBlockStructure: Bool { true }
    /// У блоков под мышью — ручки «+ ⋮⋮». В ячейке таблицы их нет.
    var showsBlockHandles: Bool { true }

    func layoutColumn() {
        let previousTextTop = textContainerOrigin.y
        let (left, columnWidth) = column
        if let container = textContainer, container.size.width != columnWidth {
            container.size = NSSize(width: columnWidth, height: container.size.height)
        }
        header.isHidden = !showsPageHeader
        let headerHeight = showsPageHeader ? header.height(forWidth: columnWidth) : 0
        let coverHeight = showsPageHeader ? coverSlot.height : 0
        coverSlot.view?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: coverHeight)
        let headerTop = coverHeight - (coverHeight > 0 ? header.coverOverlap : 0)
        header.frame = NSRect(x: left, y: headerTop, width: columnWidth, height: headerHeight)
        // Отступ текста сверху — обложка и шапка, снизу — пустое место; NSTextView делит высоту поровну, а начало текста
        // задаёт `textContainerOrigin`.
        let inset = NSSize(width: left, height: showsPageHeader ? (headerTop + headerHeight + Metrics.Page.bottomPadding) / 2 : 0)
        if textContainerInset != inset {
            textContainerInset = inset
        }
        invalidateTextContainerOrigin()
        // Шапка выросла уже после возврата места (строка обратных ссылок, обложка): блок якоря — обратно на своё место.
        if textContainerOrigin.y != previousTextTop { keepScrollAnchor() }
        updateEmptyParagraphHint()
        if formatBar.isShown { updateFormatBar() }
        updateSelectionLook()
        if !document.pendingConflicts.isEmpty { conflictMarks.update() }
    }

    // MARK: Курсор и выделение

    public override var shouldDrawInsertionPoint: Bool { false }

    /// Место текста на экране — по раскладке с начала страницы (`NSTextLayoutManager.ensureLayoutFromStart`):
    /// иначе абзац, разложенный первым после правки, остался бы на прикидочном месте.
    public override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        if let textLayoutManager, let storage = textContentStorage,
           let location = storage.location(storage.documentRange.location, offsetBy: range.location) {
            textLayoutManager.ensureLayoutFromStart(through: location)
        }
        return super.firstRect(forCharacterRange: range, actualRange: actualRange)
    }

    /// Курсор к выделению; полосы выделения перерисовать там, где они были и где стали.
    /// `isFocused: false` — текст отдаёт фокус: окно ещё считает его первым, но курсор и выделение уже гаснут.
    func updateSelectionLook(isFocused: Bool? = nil) {
        caret.update(isFocused: isFocused)
        let rects = (isFocused ?? (window?.firstResponder === self)) ? selectionHighlightRects() : []
        let isBlocks = !rects.isEmpty && isBlockSelection
        guard rects != drawnSelectionRects || isBlocks != drawnSelectionIsBlocks else { return }
        for rect in drawnSelectionRects + rects { setNeedsDisplay(rect) }
        drawnSelectionRects = rects
        drawnSelectionIsBlocks = isBlocks
    }

    /// Выделение как в Notion: под текстом. Выделение текста — полоса на строку; выделенные блоки —
    /// скруглённая подложка на блок.
    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard drawnSelectionIsBlocks else {
            Palette.textSelection.setFill()
            for highlight in drawnSelectionRects where highlight.intersects(rect) {
                highlight.fill(using: .sourceOver)
            }
            return
        }
        Palette.blockSelection.setFill()
        let radius = Metrics.BlockSelection.cornerRadius
        for highlight in drawnSelectionRects where highlight.intersects(rect) {
            NSBezierPath(roundedRect: highlight, xRadius: radius, yRadius: radius).fill()
        }
    }

    /// Подсветка выделения (координаты окна текста): выделение текста — полосы по тексту, и через блоки тоже;
    /// режим выделения блоков — подложки блоков целиком.
    func selectionHighlightRects() -> [NSRect] {
        guard let blocks = selectedBlocks else { return textSelectionRects() }
        return blockSelectionRects(blocks)
    }

    /// Подложка на блок как в Notion: от края блока (у пунктов — с маркером) до края колонки с запасом по бокам,
    /// от верха первой строки до низа последней с запасом сверху и снизу. Подложка тянется вниз до следующей,
    /// оставляя просвет `blockGap`.
    func blockSelectionRects(_ blocks: Range<Int>) -> [NSRect] {
        guard let layoutManager = textLayoutManager, let storage = textContentStorage, let container = textContainer else { return [] }
        let origin = textContainerOrigin
        let outset = Metrics.BlockSelection.horizontalOutset
        // Раскладка — с начала текста до последнего выделенного блока: TextKit раскладывает лениво, а абзац,
        // разложенный раньше предыдущих, встаёт на прикидочное место (как у курсора, `TextCaret`).
        if let end = storage.location(storage.documentRange.location,
                                      offsetBy: mapper.paragraphStart(ofBlockAt: blocks.upperBound - 1)),
           let range = NSTextRange(location: storage.documentRange.location, end: end) {
            layoutManager.ensureLayout(for: range)
        }
        var rects: [NSRect] = []
        for index in blocks where !hiddenParagraphs.isHidden(document.blocks[index].id) {
            guard let location = storage.location(storage.documentRange.location, offsetBy: mapper.paragraphStart(ofBlockAt: index)),
                  let fragment = layoutManager.textLayoutFragment(for: location) else { continue }
            let fragmentStart = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
            let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
            guard let first = lines.first, let last = lines.last else { continue }
            let top = lineBox(first, in: fragment, startingAt: fragmentStart).minY - Metrics.BlockSelection.verticalOutset
            let bottom = lineBox(last, in: fragment, startingAt: fragmentStart).maxY + Metrics.BlockSelection.verticalOutset
            let left = origin.x + blockLeft(ofBlockAt: index) - outset
            let right = origin.x + container.size.width + outset
            rects.append(NSRect(x: left, y: top, width: right - left, height: bottom - top))
        }
        for index in rects.indices.dropLast() {
            rects[index].size.height = rects[index + 1].minY - Metrics.BlockSelection.blockGap - rects[index].minY
        }
        return rects
    }

    /// Строка текста в высоту строки абзаца с серединой на середине шрифта, как строка в CSS (координаты окна текста).
    private func lineBox(_ line: NSTextLineFragment, in fragment: NSTextLayoutFragment, startingAt fragmentStart: Int,
                         font knownFont: NSFont? = nil) -> NSRect {
        let lineStart = fragmentStart + line.characterRange.location
        let font = knownFont ?? textStorage?.attribute(.font, at: lineStart, effectiveRange: nil) as? NSFont ?? Typography.line(for: .paragraph).font
        let bounds = line.typographicBounds
        let styledHeight = (textStorage?.attribute(.paragraphStyle, at: lineStart, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight ?? 0
        let lineHeight = styledHeight > 0 ? styledHeight : bounds.height
        let origin = textContainerOrigin
        let frame = fragment.layoutFragmentFrame
        let baseline = origin.y + frame.minY + bounds.minY + line.glyphOrigin.y
        let top = baseline - font.ascender - (lineHeight - (font.ascender - font.descender)) / 2
        return NSRect(x: origin.x + frame.minX + bounds.minX, y: top, width: bounds.width, height: lineHeight)
    }

    /// Полосы выделения внутри блока: на строку — от начала до конца выделенного в ней текста, высотой в строку.
    /// Номера и маркеры не закрашены; выделенный перевод строки — полоса шириной в пробел за текстом.
    private func textSelectionRects() -> [NSRect] {
        let selection = selectedRange()
        guard selection.length > 0, let layoutManager = textLayoutManager, let storage = textContentStorage, let text = textStorage,
              let start = storage.location(storage.documentRange.location, offsetBy: selection.location) else { return [] }
        let string = text.string as NSString
        var rects: [NSRect] = []
        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let fragmentStart = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
            guard fragmentStart < NSMaxRange(selection) else { return false }
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                let lineStart = fragmentStart + line.characterRange.location
                var textEnd = lineStart + line.characterRange.length
                let endsParagraph = [PageTextStorageMapper.newline, PageTextStorageMapper.lineSeparator].contains(string.character(at: textEnd - 1))
                if endsParagraph { textEnd -= 1 }
                let from = max(selection.location, lineStart)
                let to = min(NSMaxRange(selection), textEnd)
                let coversNewline = endsParagraph && selection.location <= textEnd && NSMaxRange(selection) > textEnd
                guard to > from || coversNewline else { continue }
                let font = text.attribute(.font, at: max(lineStart, min(to, textEnd) - (to > lineStart ? 1 : 0)), effectiveRange: nil) as? NSFont
                    ?? Typography.line(for: .paragraph).font
                let box = lineBox(line, in: fragment, startingAt: fragmentStart, font: font)
                let minX = box.minX + line.locationForCharacter(at: from - fragmentStart).x
                var maxX = box.minX + line.locationForCharacter(at: max(from, to) - fragmentStart).x
                if coversNewline { maxX += (" " as NSString).size(withAttributes: [.font: font]).width }
                rects.append(NSRect(x: minX, y: box.minY, width: maxX - minX, height: box.height))
            }
            return true
        }
        return rects
    }

    // MARK: Доступность

    /// Название и ручки «+ ⋮⋮» — вложенные поля текста; доступность текстового поля сама их не показывает,
    /// и без этого их не находят ни VoiceOver, ни UI-сценарии.
    public override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + NSAccessibility.unignoredChildren(from: subviews.filter { !$0.isHidden })
    }

    /// Текст блоков без служебного перевода строки в конце: строка после него — не блок.
    /// Упоминания и даты читаются названием и словами, а не знаком-вложением.
    public override func accessibilityValue() -> String? {
        let text = plainText(of: NSRange(location: 0, length: (string as NSString).length))
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    // MARK: Фокус

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let focus = pendingFocus else { return }
        pendingFocus = nil
        // Место прокрутки вкладки — до первой отрисовки: страница сразу на месте, без лишнего кадра сверху.
        if pendingScrollPlace != nil, (enclosingScrollView?.contentSize.width ?? 0) > 0 { restorePendingScrollPlace() }
        // Следующий оборот цикла событий: окно уже на экране и принимает ввод.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let restored = restorePendingScrollPlace()
            switch focus {
            case .title: header.focusTitle()
            case .body where restored: window?.makeFirstResponder(self)
            case .body: focusBody(at: 0)
            case .bodyWithoutCaret:
                isCaretHiddenUntilUserAction = true
                window?.makeFirstResponder(self)
            case .unchanged: break
            }
            onReady?()
        }
    }

    /// Вернуть место прокрутки вкладки, если оно ждёт; `true` — место вернули (сейчас или раньше).
    @discardableResult
    private func restorePendingScrollPlace() -> Bool {
        guard let place = pendingScrollPlace else { return didRestoreScrollPlace }
        pendingScrollPlace = nil
        restoreScrollPlace(place)
        didRestoreScrollPlace = true
        return true
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

/// Поле названия: правится своим редактором — курсор и выделение как в блоках, а не системные.
final class PageTitleField: NSTextField {
    override class var cellClass: AnyClass? {
        get { PageTitleFieldCell.self }
        set {}
    }
}

private final class PageTitleFieldCell: NSTextFieldCell {
    private lazy var editor = PageTitleEditor.make()

    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        if let editor = editor as? PageTitleEditor {
            editor.insertionPointColor = .clear
            editor.selectedTextAttributes = [.backgroundColor: Palette.textSelection]
        }
        return editor
    }
}
