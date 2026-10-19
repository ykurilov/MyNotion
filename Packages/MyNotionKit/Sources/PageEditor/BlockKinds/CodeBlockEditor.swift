import AppKit
import CodeHighlighting
import NotesCore
import VisualStyle

/// Блок кода на странице (research R5, «Решение 19.10.2026»): абзац-вложение, в его виде — свой `NSTextView` на TextKit 2,
/// где строка кода — свой абзац: правка перекладывает одну строку, а не весь блок (проба R16: один абзац на 500 строк —
/// 310 мс на букву). Код хранится в `text` блока (строки через `\n`) и пишется в документ по каждой правке.
/// Подсветка — атрибуты показа (`setRenderingAttributes`): их нет в тексте, документе и отмене.

/// Размеры и цвета блока кода (contracts/blocks-and-keys.md, «Блок кода»; сверено с Notion — см. там же).
enum CodeBlockStyle {
    static let fontSize = Typography.line(for: .paragraph).fontSize * Typography.inlineCodeScale
    static let lineHeight: CGFloat = (fontSize * 1.5).rounded()
    static var font: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    /// Поля текста внутри подложки, как у Notion: сверху место под строку языка.
    /// Сверено с Notion 19.10.2026: текст в 24 от левого края, первая строка — в 34 от верха, под последней — 36.
    static let padding = NSEdgeInsets(top: 34, left: 24, bottom: 36, right: 16)
    static let cornerRadius: CGFloat = 4
    /// Отступ блока от соседних абзацев.
    static let outerSpacing: CGFloat = 4

    static let background = themed(light: 0xF9F8F7, dark: 0x202020)
    static let text = Palette.textPrimary
    static let chromeText = Palette.textSecondary

    /// Высота вида блока с `lineCount` строками кода.
    static func height(lineCount: Int) -> CGFloat {
        padding.top + padding.bottom + CGFloat(max(1, lineCount)) * lineHeight
    }

    static func height(of code: String) -> CGFloat {
        height(lineCount: code.utf16.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 })
    }

    /// Цвета токенов как у Notion (сняты с живого Notion 19.10.2026): светлая тема — Prism по умолчанию,
    /// тёмная — своя тема Notion (комментарии, строки и числа — как у prism-dark, ключевые слова голубые,
    /// функции жёлтые).
    private static let tokenColors: [CodeTokenKind: NSColor] = [
        .keyword: themed(light: 0x0077AA, dark: 0x66A2CC),
        .type: themed(light: 0xDD4A68, dark: 0xECEC93),
        .string: themed(light: 0x669900, dark: 0xBDE052),
        .number: themed(light: 0x990055, dark: 0xD1949E),
        .comment: themed(light: 0x708090, dark: 0x998066),
        .function: themed(light: 0xDD4A68, dark: 0xECEC93),
        .literal: themed(light: 0x990055, dark: 0xD1949E),
        .property: themed(light: 0x990055, dark: 0xD1949E),
        .tag: themed(light: 0x990055, dark: 0xD1949E),
        .attribute: themed(light: 0x669900, dark: 0xBDE052),
        .variable: themed(light: 0xEE9900, dark: 0xF4B73D),
        .annotation: themed(light: 0x0077AA, dark: 0x66A2CC),
        .operator: themed(light: 0x9A6E3A, dark: 0xF4B73D),
        .punctuation: themed(light: 0x999999, dark: 0xA8A7A5),
    ]

    static func color(for kind: CodeTokenKind) -> NSColor? { tokenColors[kind] }

    private static func themed(light: UInt32, dark: UInt32) -> NSColor {
        func color(_ value: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light) }
    }
}

/// Последний выбранный язык: новый блок кода берёт его, сначала — «Простой текст» (contracts, «Быстрые символы»).
enum CodeLanguageMemory {
    static let defaultsKey = "MyNotion.lastCodeLanguage"

    @MainActor static var last: String {
        get { UserDefaults.standard.string(forKey: defaultsKey) ?? LanguageDefinition.plain.id }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

/// Куда поставить курсор в редакторе кода.
enum CodeCaret: Equatable {
    case start
    case end
    case location(Int)
}

/// Виды блоков кода страницы по id блока: переход курсора со страницы в код и обратно, ожидающий фокус,
/// склейка набора в один шаг отмены. Вид, в котором идёт правка, держится сильной ссылкой: TextKit может пересоздать
/// вложение (смена высоты), и тогда в новую рамку встаёт тот же вид, с курсором и выделением.
@MainActor
final class CodeBlockRegistry {
    private final class WeakView {
        weak var view: CodeBlockView?
        init(_ view: CodeBlockView) { self.view = view }
    }

    private var views: [UUID: WeakView] = [:]
    /// Вид, в котором сейчас курсор.
    var editing: CodeBlockView?
    /// Блок, которому отдать курсор, когда его вид появится (страница ещё не разложила его строку).
    var pendingFocus: (blockId: UUID, caret: CodeCaret)?
    /// Набор, который склеивается в один шаг отмены: блок и вид правки.
    var typing: (blockId: UUID, kind: CodeEditKind)?

    func view(for blockId: UUID) -> CodeBlockView? {
        views[blockId]?.view
    }

    func register(_ view: CodeBlockView) {
        views = views.filter { $0.value.view != nil }
        views[view.blockId] = WeakView(view)
    }

    func breakTyping() {
        typing = nil
    }
}

/// Вид правки кода: набор и удаление склеиваются в шаг отмены каждый со своими, остальное — отдельным шагом.
enum CodeEditKind: Equatable {
    case typing
    case deleting
    case other
}

/// Фабрика вида блока кода для знака-вложения (`BlockViewFactories`).
@MainActor
final class CodeBlockViewFactory: BlockViewFactory {
    func makeView(for block: Block, context: BlockViewContext) -> NSView? {
        guard let textView = context.textView else { return CodeBlockView(block: block, page: nil) }
        if let existing = textView.codeBlocks.view(for: block.id) {
            existing.update(block)
            return existing
        }
        let view = CodeBlockView(block: block, page: textView)
        textView.codeBlocks.register(view)
        return view
    }

    func height(for block: Block, width: CGFloat) -> CGFloat? {
        CodeBlockStyle.height(of: block.text.string) + 2 * CodeBlockStyle.outerSpacing
    }
}

/// Вид блока кода: подложка, редактор кода с прокруткой вбок (строки не переносятся), язык и «Копировать» сверху.
@MainActor
final class CodeBlockView: NSView, BlockFieldsView {
    let blockId: UUID
    private(set) var block: Block
    weak var page: PageTextView?
    let textView: CodeTextView
    let scrollView = CodeScrollView()
    let languageButton = NSButton(title: "", target: nil, action: nil)
    let copyButton = NSButton(title: CodeBlockView.copyTitle, target: nil, action: nil)
    /// Буфер для «Копировать»; тесты подменяют, чтобы не трогать общий.
    var pasteboard = NSPasteboard.general
    private(set) var highlighter: IncrementalHighlighter
    /// Текст после последней передачи документу: с ним сравнивается правка.
    private(set) var syncedText: String
    /// Текст меняет сам вид (отмена, правка с другого Mac) — это не правка пользователя.
    private var isApplyingText = false
    /// Правки текста с прошлой подсветки: одна — перекрасить её строки, больше — весь блок.
    private var pendingEdits: [(range: NSRange, delta: Int)] = []
    private var hoverArea: NSTrackingArea?
    private(set) var isHovered = false
    private var copyResetTask: Task<Void, Never>?

    static let copyTitle = "Копировать"
    static let copiedTitle = "Скопировано"

    init(block: Block, page: PageTextView?) {
        blockId = block.id
        self.block = block
        self.page = page
        syncedText = block.text.string
        highlighter = IncrementalHighlighter(language: .forBlock(block.props.language), text: block.text.string)
        textView = CodeTextView.make()
        super.init(frame: NSRect(x: 0, y: 0, width: 720, height: CodeBlockStyle.height(of: block.text.string)))
        wantsLayer = true
        textView.codeView = self
        textView.textStorage?.delegate = self
        isApplyingText = true
        textView.string = block.text.string
        isApplyingText = false
        pendingEdits = []
        scrollView.documentView = textView
        addSubview(scrollView)
        configureChrome()
        recolorAll()
        setAccessibilityIdentifier("code-block")
        textView.setAccessibilityIdentifier("code-editor")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    // MARK: Вид

    private var boxRect: NSRect {
        NSRect(x: 0, y: CodeBlockStyle.outerSpacing, width: bounds.width, height: max(0, bounds.height - 2 * CodeBlockStyle.outerSpacing))
    }

    override func layout() {
        super.layout()
        let box = boxRect
        let padding = CodeBlockStyle.padding
        scrollView.frame = NSRect(x: box.minX + padding.left, y: box.minY + padding.top,
                                  width: max(0, box.width - padding.left - padding.right), height: max(0, box.height - padding.top - padding.bottom))
        textView.minSize = NSSize(width: scrollView.contentSize.width, height: scrollView.contentSize.height)
        textView.frame.size.height = scrollView.contentSize.height
        if textView.frame.width < scrollView.contentSize.width { textView.frame.size.width = scrollView.contentSize.width }
        layoutChrome(in: box)
    }

    override func draw(_ dirtyRect: NSRect) {
        CodeBlockStyle.background.setFill()
        NSBezierPath(roundedRect: boxRect, xRadius: CodeBlockStyle.cornerRadius, yRadius: CodeBlockStyle.cornerRadius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ hovered: Bool) {
        isHovered = hovered
        updateChromeVisibility()
    }

    /// Щелчок по полям подложки — курсор в код, ближе к месту щелчка.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let caret: CodeCaret = point.y < scrollView.frame.minY ? .start : point.y > scrollView.frame.maxY ? .end
            : .location(textView.characterIndexForInsertion(at: textView.convert(event.locationInWindow, from: nil)))
        focus(caret)
    }

    // MARK: Блок

    /// Тот же блок с новыми полями (вид заново встал в рамку вложения или блок поправили не здесь).
    func update(_ block: Block) {
        let languageChanged = block.props.language != self.block.props.language
        self.block = block
        if block.text.string != textView.string { showText(block.text.string) }
        if languageChanged { setHighlightLanguage(.forBlock(block.props.language)) }
        updateLanguageTitle()
    }

    /// Показать текст, пришедший не из этого вида (⌘Z, другой Mac), не передавая его документу как правку.
    /// Курсор — у места изменения.
    func showText(_ text: String) {
        let old = textView.string as NSString
        let new = text as NSString
        var prefix = 0
        let limit = min(old.length, new.length)
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        isApplyingText = true
        textView.textStorage?.replaceCharacters(in: NSRange(location: prefix, length: old.length - prefix - suffix),
                                                with: new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix)))
        isApplyingText = false
        syncedText = text
        textView.setSelectedRange(NSRange(location: new.length - suffix, length: 0))
        flushHighlight()
    }

    /// Поставить курсор в код и сделать редактор первым.
    func focus(_ caret: CodeCaret) {
        window?.makeFirstResponder(textView)
        let length = (textView.string as NSString).length
        let location = switch caret {
        case .start: 0
        case .end: length
        case .location(let location): min(max(0, location), length)
        }
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let page, let pending = page.codeBlocks.pendingFocus, pending.blockId == blockId else { return }
        page.codeBlocks.pendingFocus = nil
        focus(pending.caret)
    }

    // MARK: Правки

    /// Пользователь поправил код: передать документу и обновить подсветку.
    func textDidChange(kind: CodeEditKind) {
        flushHighlight()
        let text = textView.string
        guard text != syncedText else { return }
        let old = syncedText
        syncedText = text
        page?.codeTextDidChange(ofBlock: blockId, from: old, to: text, kind: kind)
        if let current = page?.document.block(blockId) { block = current }
    }

    /// Сменить язык блока: одна правка для ⌘Z; язык запоминается для новых блоков.
    func setLanguage(_ id: String) {
        CodeLanguageMemory.last = id
        page?.setCodeLanguage(id, ofBlock: blockId)
        if let current = page?.document.block(blockId) { update(current) }
    }

    func copyCode() {
        pasteboard.clearContents()
        pasteboard.setString(textView.string, forType: .string)
        copyButton.title = Self.copiedTitle
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.copyButton.title = Self.copyTitle
        }
    }

    // MARK: Подсветка

    private func setHighlightLanguage(_ language: LanguageDefinition) {
        highlighter = IncrementalHighlighter(language: language, text: textView.string)
        pendingEdits = []
        recolor(lines: 0..<highlighter.lines.count)
    }

    private func recolorAll() {
        highlighter = IncrementalHighlighter(language: highlighter.language, text: textView.string)
        recolor(lines: 0..<highlighter.lines.count)
    }

    /// Перекрасить строки после правок: одна правка — её строки и следующие до совпадения состояния, иначе весь блок.
    func flushHighlight() {
        let edits = pendingEdits
        pendingEdits = []
        guard !edits.isEmpty else { return }
        guard edits.count == 1, let edit = edits.first else { return recolorAll() }
        let lines = highlighter.apply(text: textView.string, editedRange: edit.range, changeInLength: edit.delta)
        recolor(lines: lines)
    }

    private func recolor(lines: Range<Int>) {
        guard let layoutManager = textView.textLayoutManager, let storage = textView.textContentStorage, !lines.isEmpty else { return }
        let start = highlighter.lineStarts[lines.lowerBound]
        let end = highlighter.lineRange(lines.upperBound - 1).upperBound
        guard let whole = Self.textRange(NSRange(location: start, length: end - start), in: storage) else { return }
        layoutManager.removeRenderingAttribute(.foregroundColor, for: whole)
        for token in highlighter.tokens(inLines: lines) {
            guard let color = CodeBlockStyle.color(for: token.kind),
                  let range = Self.textRange(NSRange(location: token.range.lowerBound, length: token.range.count), in: storage) else { continue }
            layoutManager.addRenderingAttribute(.foregroundColor, value: color, for: range)
        }
    }

    private static func textRange(_ range: NSRange, in storage: NSTextContentStorage) -> NSTextRange? {
        guard let from = storage.location(storage.documentRange.location, offsetBy: range.location),
              let to = storage.location(from, offsetBy: range.length) else { return nil }
        return NSTextRange(location: from, end: to)
    }

    /// Цвет подсветки у знака `location`; `nil` — без подсветки.
    func renderedColor(at location: Int) -> NSColor? {
        guard let layoutManager = textView.textLayoutManager, let storage = textView.textContentStorage,
              let point = storage.location(storage.documentRange.location, offsetBy: location) else { return nil }
        var found: NSColor?
        layoutManager.enumerateRenderingAttributes(from: point, reverse: false) { _, attributes, range in
            if range.contains(point) || range.location.compare(point) == .orderedSame { found = attributes[.foregroundColor] as? NSColor }
            return false
        }
        return found
    }

    // MARK: Язык и «Копировать»

    private func configureChrome() {
        for button in [languageButton, copyButton] {
            button.isBordered = false
            button.bezelStyle = .inline
            button.font = NSFont.systemFont(ofSize: 12)
            button.contentTintColor = CodeBlockStyle.chromeText
            button.target = self
            addSubview(button)
        }
        languageButton.action = #selector(openLanguagePicker)
        languageButton.setAccessibilityIdentifier("code-language")
        copyButton.action = #selector(copyButtonPressed)
        copyButton.setAccessibilityIdentifier("code-copy")
        updateLanguageTitle()
        updateChromeVisibility()
    }

    private func updateLanguageTitle() {
        let title = LanguageDefinition.forBlock(block.props.language).title + " ▾"
        languageButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: CodeBlockStyle.chromeText,
        ])
        languageButton.title = title
        languageButton.sizeToFit()
        needsLayout = true
    }

    /// Язык и «Копировать» видны под мышью и в блоке с курсором, как у Notion.
    func updateChromeVisibility() {
        let visible = isHovered || window?.firstResponder === textView
        languageButton.isHidden = !visible
        copyButton.isHidden = !visible
    }

    private func layoutChrome(in box: NSRect) {
        languageButton.sizeToFit()
        copyButton.sizeToFit()
        // Как у Notion: язык и «Копировать» — справа сверху, язык левее.
        let top = box.minY + 6
        copyButton.frame.origin = NSPoint(x: box.maxX - 8 - copyButton.frame.width, y: top)
        languageButton.frame.origin = NSPoint(x: copyButton.frame.minX - 8 - languageButton.frame.width, y: top)
    }

    @objc private func copyButtonPressed() { copyCode() }

    @objc private func openLanguagePicker() {
        CodeLanguagePicker.shared.show(below: languageButton, selected: block.props.language) { [weak self] id in
            self?.setLanguage(id)
        }
    }
}

extension CodeBlockView: NSTextStorageDelegate {
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { pendingEdits.append((editedRange, delta)) }
    }
}

/// Прокрутка кода вбок; прокрутка колесом вверх и вниз уходит странице.
final class CodeScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        drawsBackground = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .allowed
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Редактор кода: простой текст SF Mono без переносов, строка — абзац. Своей отмены нет — шаги регистрирует страница
/// (`PageTextView.codeTextDidChange`) в общем `UndoManager` окна.
final class CodeTextView: NSTextView {
    weak var codeView: CodeBlockView?
    /// Что делает текущая правка: набор и удаление склеиваются в шаг отмены.
    private var editKind: CodeEditKind = .other
    /// Курсор двигает сама правка — склейку набора это не прерывает.
    private var isEditing = false

    static func make() -> CodeTextView {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: CodeBlockStyle.lineHeight), textContainer: container)
        textView.configure()
        return textView
    }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = false
        usesFindBar = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        drawsBackground = false
        isHorizontallyResizable = true
        isVerticallyResizable = false
        autoresizingMask = []
        textContainerInset = .zero
        insertionPointColor = Palette.textPrimary
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = CodeBlockStyle.lineHeight
        paragraph.maximumLineHeight = CodeBlockStyle.lineHeight
        let font = CodeBlockStyle.font
        typingAttributes = [.font: font, .foregroundColor: CodeBlockStyle.text, .paragraphStyle: paragraph]
        defaultParagraphStyle = paragraph
        self.font = font
        textColor = CodeBlockStyle.text
    }

    override var undoManager: UndoManager? {
        codeView?.page?.undoManager ?? super.undoManager
    }

    /// Свою отмену набора `NSTextView` не ведёт: шаги правки кода — у страницы.
    override var allowsUndo: Bool {
        get { false }
        set {}
    }

    /// `NSTextView` на TextKit 2 записывает свой шаг «Typing» и с `allowsUndo == false`: на время его правки
    /// запись в отмену выключена, шаг кода регистрирует страница после правки.
    private var isUndoRegistrationPaused = false

    private func pauseUndoRegistration() {
        guard !isUndoRegistrationPaused, let undoManager else { return }
        undoManager.disableUndoRegistration()
        isUndoRegistrationPaused = true
    }

    private func resumeUndoRegistration() {
        guard isUndoRegistrationPaused else { return }
        undoManager?.enableUndoRegistration()
        isUndoRegistrationPaused = false
    }

    /// Код — простой текст: всё набранное и вставленное получает вид кода.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        isEditing = true
        pauseUndoRegistration()
        let accepted = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if !accepted {
            resumeUndoRegistration()
            isEditing = false
        }
        return accepted
    }

    override func didChangeText() {
        super.didChangeText()
        resumeUndoRegistration()
        if let storage = textStorage, storage.length > 0 {
            storage.setAttributes(typingAttributes, range: NSRange(location: 0, length: storage.length))
        }
        isEditing = false
        guard !hasMarkedText() else { return }
        codeView?.textDidChange(kind: editKind)
        editKind = .other
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        editKind = typed.count == 1 && replacementRange.location == NSNotFound ? .typing : .other
        super.insertText(string, replacementRange: replacementRange)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        // Курсор сдвинули мышью или стрелками — следующий набор будет новым шагом отмены.
        if !isEditing { codeView?.page?.codeBlocks.breakTyping() }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let codeView {
            codeView.page?.codeBlocks.editing = codeView
            codeView.page?.codeBlocks.breakTyping()
            codeView.updateChromeVisibility()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let codeView {
            if codeView.page?.codeBlocks.editing === codeView { codeView.page?.codeBlocks.editing = nil }
            codeView.page?.codeEditingDidEnd(ofBlock: codeView.blockId)
            codeView.updateChromeVisibility()
        }
        return resigned
    }

    // MARK: Клавиши

    private var nsString: NSString { string as NSString }

    /// Enter — новая строка с отступом текущей строки.
    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let line = nsString.lineRange(for: NSRange(location: selection.location, length: 0))
        var indentEnd = line.location
        while indentEnd < selection.location, nsString.character(at: indentEnd) == 0x20 || nsString.character(at: indentEnd) == 0x09 {
            indentEnd += 1
        }
        let indent = nsString.substring(with: NSRange(location: line.location, length: indentEnd - line.location))
        editKind = .typing
        insertTextReplacingSelection("\n" + indent)
    }

    /// ⇧Enter в коде — тоже новая строка.
    override func insertLineBreak(_ sender: Any?) { insertNewline(sender) }

    /// Tab — два пробела у курсора; у выделения через строки — в начале каждой строки.
    override func insertTab(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0 else {
            editKind = .other
            insertTextReplacingSelection("  ")
            return
        }
        changeLines(in: selection) { "  " + $0 }
    }

    /// ⇧Tab — убрать до двух пробелов в начале строки (или каждой строки выделения).
    override func insertBacktab(_ sender: Any?) {
        changeLines(in: selectedRange()) { line in
            var removed = 0
            var rest = Substring(line)
            while removed < 2, rest.first == " " {
                rest.removeFirst()
                removed += 1
            }
            if removed == 0, rest.first == "\t" { rest.removeFirst() }
            return String(rest)
        }
    }

    /// Заменить строки, которых касается `selection`, одной правкой; выделение — снова на эти строки.
    private func changeLines(in selection: NSRange, _ transform: (String) -> String) {
        let lines = nsString.lineRange(for: selection)
        var block = nsString.substring(with: lines)
        let endsWithNewline = block.hasSuffix("\n")
        if endsWithNewline { block.removeLast() }
        let changed = block.components(separatedBy: "\n").map(transform).joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        guard changed != nsString.substring(with: lines) else { return }
        editKind = .other
        guard shouldChangeText(in: lines, replacementString: changed) else { return }
        textStorage?.replaceCharacters(in: lines, with: changed)
        let length = (changed as NSString).length - (endsWithNewline ? 1 : 0)
        setSelectedRange(selection.length > 0 ? NSRange(location: lines.location, length: length)
                                              : NSRange(location: min(lines.location + length, nsString.length), length: 0))
        didChangeText()
    }

    private func insertTextReplacingSelection(_ text: String) {
        let selection = selectedRange()
        guard shouldChangeText(in: selection, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: selection, with: text)
        // Курсор — до конца правки: иначе его сдвиг прервал бы склейку набора в один шаг отмены.
        setSelectedRange(NSRange(location: selection.location + (text as NSString).length, length: 0))
        didChangeText()
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection == NSRange(location: 0, length: 0), let codeView, let page = codeView.page {
            // ⌫ в начале пустого кода — абзац, как у Notion; в начале непустого — ничего.
            if nsString.length == 0 { page.convertEmptyCodeToParagraph(codeView.blockId) }
            return
        }
        editKind = .deleting
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        editKind = .deleting
        super.deleteForward(sender)
    }

    /// ↑ на первой строке — в блок над кодом.
    override func moveUp(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, !nsString.substring(to: selection.location).contains("\n"), let codeView, let page = codeView.page {
            page.leaveCode(codeView.blockId, direction: .up)
            return
        }
        super.moveUp(sender)
    }

    /// ↓ на последней строке — в блок под кодом; под кодом ничего нет — новый абзац.
    override func moveDown(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, !nsString.substring(from: selection.location).contains("\n"), let codeView, let page = codeView.page {
            page.leaveCode(codeView.blockId, direction: .down)
            return
        }
        super.moveDown(sender)
    }

    /// ← в самом начале — в конец блока выше.
    override func moveLeft(_ sender: Any?) {
        if selectedRange() == NSRange(location: 0, length: 0), let codeView, let page = codeView.page {
            page.leaveCode(codeView.blockId, direction: .up)
            return
        }
        super.moveLeft(sender)
    }

    /// → в самом конце — в начало блока ниже.
    override func moveRight(_ sender: Any?) {
        if selectedRange() == NSRange(location: nsString.length, length: 0), let codeView, let page = codeView.page {
            page.leaveCode(codeView.blockId, direction: .down)
            return
        }
        super.moveRight(sender)
    }

    /// Esc — выделить блок кода целиком (режим блоков страницы).
    override func cancelOperation(_ sender: Any?) {
        guard let codeView, let page = codeView.page else { return }
        page.window?.makeFirstResponder(page)
        page.attachmentViewClicked(blockId: codeView.blockId)
    }

    /// ⌘Enter — выйти из кода: новый абзац под блоком.
    func exitBelow() {
        guard let codeView, let page = codeView.page else { return }
        page.insertParagraph(belowCode: codeView.blockId)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, Self.isCommandReturn(event) {
            exitBelow()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if Self.isCommandReturn(event) { return exitBelow() }
        super.keyDown(with: event)
    }

    static func isCommandReturn(_ event: NSEvent) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command]
    }
}
