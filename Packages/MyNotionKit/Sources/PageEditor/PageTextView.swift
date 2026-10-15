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
    private let emptyParagraphHint = NSTextField(labelWithString: "Введите «/» для выбора блока")

    /// Куда поставить курсор, когда страница появится в окне.
    public enum InitialFocus { case title, body }
    private var pendingFocus: InitialFocus?
    /// Страница показана и принимает ввод.
    public var onReady: (@MainActor () -> Void)?

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

        configureTextBehaviour()
        mapper = PageTextStorageMapper(document: document, textStorage: textStorage!)
        mapper.load()

        addSubview(header)
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
        isContinuousSpellCheckingEnabled = true
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

    public override func didChangeText() {
        super.didChangeText()
        // Посреди набора с помощью IME текст ещё не окончательный.
        guard !hasMarkedText() else { return }
        mapper.commitPendingEdits()
        updateEmptyParagraphHint()
    }

    /// Вставка — простым текстом: оформление чужих программ на страницу не переносится.
    public override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !stillSelecting else { return }
        applyTrailingParagraphTypingAttributes()
        updateEmptyParagraphHint()
    }

    /// У пустого последнего абзаца нет символов, с которых `NSTextView` взял бы вид набора, — берём его блок.
    private func applyTrailingParagraphTypingAttributes() {
        let length = textStorage?.length ?? 0
        guard selectedRange().length == 0, selectedRange().location == length, isAtEmptyParagraph(length),
              let last = document.blocks.last else { return }
        typingAttributes = PageTextStorageMapper.typingAttributes(for: last)
    }

    private func isAtEmptyParagraph(_ location: Int) -> Bool {
        let string = (textStorage?.string ?? "") as NSString
        let atParagraphStart = location == 0 || string.character(at: location - 1) == 0x0A
        let atParagraphEnd = location == string.length || string.character(at: location) == 0x0A
        return atParagraphStart && atParagraphEnd
    }

    // MARK: Подсказка в пустом абзаце

    public override func becomeFirstResponder() -> Bool {
        defer { updateEmptyParagraphHint() }
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        defer { emptyParagraphHint.isHidden = true }
        return super.resignFirstResponder()
    }

    /// «Введите «/» для выбора блока» у курсора в пустом абзаце (contracts/visual-style.md, «Пустые строки»).
    private func updateEmptyParagraphHint() {
        let selection = selectedRange()
        guard window?.firstResponder === self, selection.length == 0, !hasMarkedText(),
              isAtEmptyParagraph(selection.location), let window else {
            emptyParagraphHint.isHidden = true
            return
        }
        let caretOnScreen = firstRect(forCharacterRange: selection, actualRange: nil)
        let caret = convert(window.convertFromScreen(caretOnScreen), from: nil)
        let font = typingAttributes[.font] as? NSFont ?? Typography.line(for: .paragraph).font
        emptyParagraphHint.font = font
        emptyParagraphHint.sizeToFit()
        let size = emptyParagraphHint.frame.size
        emptyParagraphHint.frame = NSRect(x: caret.minX, y: caret.midY - size.height / 2, width: size.width, height: size.height)
        emptyParagraphHint.isHidden = false
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
public final class PageHeaderView: NSView, NSTextFieldDelegate {
    private let iconLabel = NSTextField(labelWithString: "")
    let titleField = NSTextField(string: "")
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
        titleField.placeholderAttributedString = NSAttributedString(string: Page.untitledTitle, attributes: [
            .font: titleStyle.font, .foregroundColor: Palette.textSecondary,
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
        iconLabel.frame = NSRect(x: 0, y: Metrics.Page.headerTopPadding, width: Metrics.Page.iconSize, height: Metrics.Page.iconSize)
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
