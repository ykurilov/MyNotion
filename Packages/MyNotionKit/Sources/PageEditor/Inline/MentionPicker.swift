import AppKit
import NotesCore
import VisualStyle

/// Строка окна «@»: страница или дата.
struct MentionPickerItem: Equatable {
    enum Target: Equatable {
        case page(UUID)
        case date(DateMention)
    }

    var title: String
    var icon: String?
    var path: [String]
    var target: Target

    var pageId: UUID? {
        if case .page(let id) = target { id } else { nil }
    }

    var identifier: String {
        switch target {
        case .page(let id): "mention-page-\(id.uuidString.lowercased())"
        case .date(let date): "mention-date-\(date.start)"
        }
    }
}

/// Что набрали, чтобы открыть окно: «@» — страницы и даты, «[[» — только страницы.
enum MentionTrigger: Equatable {
    case at
    case brackets

    var length: Int { self == .at ? 1 : 2 }
}

/// Упоминания и даты этого редактора: справочник, поиск страниц, часы и окно «@».
@MainActor
final class InlineAtomsState {
    var directory = MentionDirectory()
    var lookup: (any PageLookup)?
    var now: () -> Date = Date.init
    var calendar: Calendar = .current
    let picker = MentionPickerController()
    let datePopover = DatePickerPopoverController()
    /// Первое «Напомнить»: спросить разрешение macOS. `false` — отказ, показать подсказку.
    var requestReminderPermission: (@MainActor () async -> Bool)?
}

/// Окно «@» и «[[» (contracts/blocks-and-keys.md, «Упоминания»): поиск страниц по названию до 8 строк
/// «иконка + название + путь», под «@» — ещё даты; ↑↓, Enter, Esc. Ввод остаётся в тексте, как у меню «/».
@MainActor
final class MentionPickerController {
    struct Session: Equatable {
        var trigger: MentionTrigger
        var blockId: UUID
        /// Где начинается «@» или «[[» в тексте.
        var location: Int
        /// Длина набора, при которой последний раз что-то нашлось: дальше 3 знаков без находок окно закрывается.
        var matchedQueryLength = 0
    }

    static let pageLimit = 8
    /// Набор длиннее — окно закрывается, как у Notion.
    static let queryLimit = 40

    weak var textView: PageTextView?
    private(set) var session: Session?
    private var window: MentionPickerWindow?
    private var anchor: NSRect = .zero
    private var deactivationObserver: NSObjectProtocol?

    var isOpen: Bool { session != nil }
    var visibleItems: [MentionPickerItem] { window?.pickerView.items ?? [] }
    var selectedItem: MentionPickerItem? { window?.pickerView.selectedItem }

    func open(_ session: Session, items: [MentionPickerItem], below anchor: NSRect) {
        guard let textView, let parent = textView.window else { return }
        if window == nil { window = MentionPickerWindow() }
        self.session = session
        self.anchor = anchor
        guard let window else { return }
        window.pickerView.onChoose = { [weak self] item in self?.choose(item) }
        window.pickerView.setItems(items)
        window.show(below: anchor, parent: parent)
        if deactivationObserver == nil { deactivationObserver = PopupWindows.onAppDeactivation { [weak self] in self?.close() } }
    }

    func update(items: [MentionPickerItem], matchedQueryLength: Int) {
        session?.matchedQueryLength = matchedQueryLength
        guard let window, let parent = textView?.window else { return }
        if items.isEmpty {
            window.pickerView.setItems([])
            window.hide()
            return
        }
        guard items != window.pickerView.items || !window.isVisible else { return }
        window.pickerView.setItems(items)
        window.show(below: anchor, parent: parent)
    }

    func moveSelection(by delta: Int) { window?.pickerView.moveSelection(by: delta) }

    func choose(_ item: MentionPickerItem? = nil) {
        guard let session, let item = item ?? selectedItem else { return }
        close()
        textView?.insertAtom(for: item, replacingFrom: session.location)
    }

    func close() {
        session = nil
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        deactivationObserver = nil
        window?.hide()
    }

    /// Строки окна для набора `query`: страницы, под «@» — ещё даты; набранная дата — первой.
    func items(for query: String, trigger: MentionTrigger, lookup: (any PageLookup)?, now: Date, calendar: Calendar) -> [MentionPickerItem] {
        let pages = (lookup?.pages(matching: query, limit: Self.pageLimit) ?? []).map {
            MentionPickerItem(title: $0.title.isEmpty ? Page.untitledTitle : $0.title, icon: $0.icon, path: $0.path, target: .page($0.pageId))
        }
        guard trigger == .at else { return pages }
        let dates = DateQuery.suggestions(for: query, now: now, calendar: calendar).map {
            MentionPickerItem(title: $0.title, icon: nil, path: [], target: .date($0.mention))
        }
        let typedDate = DateQuery.parse(query, now: now, calendar: calendar) != nil
        return typedDate ? dates + pages : pages + dates
    }
}

extension PageTextView {
    // MARK: Упоминания и даты — доступ хозяина

    /// Названия, иконки и корзина страниц для упоминаний; смена перерисовывает упоминания.
    public var mentionDirectory: MentionDirectory {
        get { inlineAtoms.directory }
        set {
            guard newValue != inlineAtoms.directory else { return }
            inlineAtoms.directory = newValue
            redrawInlineAtoms()
        }
    }

    /// Поиск страниц для окна «@».
    public var pageLookup: (any PageLookup)? {
        get { inlineAtoms.lookup }
        set { inlineAtoms.lookup = newValue }
    }

    /// Часы и календарь для «Сегодня», «Завтра» и просроченных напоминаний; тесты подменяют.
    public var now: () -> Date {
        get { inlineAtoms.now }
        set { inlineAtoms.now = newValue }
    }

    public var calendar: Calendar {
        get { inlineAtoms.calendar }
        set { inlineAtoms.calendar = newValue }
    }

    /// Первое «Напомнить» спрашивает разрешение macOS (research R11).
    public var onRequestReminderPermission: (@MainActor () async -> Bool)? {
        get { inlineAtoms.requestReminderPermission }
        set { inlineAtoms.requestReminderPermission = newValue }
    }

    var mentionPicker: MentionPickerController {
        inlineAtoms.picker.textView = self
        return inlineAtoms.picker
    }

    // MARK: Окно «@»

    /// «@» в начале абзаца или после пробела, «[[» где угодно — открыть окно.
    func openMentionPicker(afterTyping typed: String) {
        guard typed == "@" || typed == "[", !hasMarkedText() else { return }
        let caret = selectedRange()
        guard caret.length == 0, let position = mapper.blockPosition(at: caret.location) else { return }
        let block = document.blocks[position.index]
        guard !block.kind.rendersAsAttachment, block.kind != .pageLink else { return }
        let string = (textStorage?.string ?? "") as NSString
        let trigger: MentionTrigger
        if typed == "@" {
            let at = caret.location - 1
            let startsWord = position.offset == 1 || Character(UnicodeScalar(string.character(at: at - 1)) ?? " ").isWhitespace
            guard startsWord else { return }
            trigger = .at
        } else {
            guard position.offset >= 2, string.character(at: caret.location - 2) == 0x5B else { return }
            trigger = .brackets
        }
        let location = caret.location - trigger.length
        let anchor = firstRect(forCharacterRange: NSRange(location: location, length: trigger.length), actualRange: nil)
        let picker = mentionPicker
        picker.open(MentionPickerController.Session(trigger: trigger, blockId: block.id, location: location),
                    items: picker.items(for: "", trigger: trigger, lookup: pageLookup, now: now(), calendar: calendar), below: anchor)
    }

    /// Окно следует за набором: ищет по набранному после «@» и закрывается, если курсор ушёл из абзаца,
    /// «@» стёрт, набор слишком длинный или ничего не подходит.
    func refreshMentionPicker() {
        let picker = mentionPicker
        guard let session = picker.session else { return }
        let caret = selectedRange()
        let string = (textStorage?.string ?? "") as NSString
        let queryStart = session.location + session.trigger.length
        let triggerText = session.trigger == .at ? "@" : "[["
        guard caret.length == 0, caret.location >= queryStart, queryStart <= string.length,
              string.substring(with: NSRange(location: session.location, length: session.trigger.length)) == triggerText,
              let position = mapper.blockPosition(at: caret.location), document.blocks[position.index].id == session.blockId,
              position.offset >= caret.location - session.location, caret.location - queryStart <= MentionPickerController.queryLimit else {
            picker.close()
            return
        }
        let query = string.substring(with: NSRange(location: queryStart, length: caret.location - queryStart))
        guard !query.contains("\n"), !query.contains(PageTextStorageMapper.lineSeparatorString) else {
            picker.close()
            return
        }
        let items = picker.items(for: query, trigger: session.trigger, lookup: pageLookup, now: now(), calendar: calendar)
        if !items.isEmpty {
            picker.update(items: items, matchedQueryLength: query.count)
        } else if session.trigger == .at && DateQuery.mayBecomeDate(query) || query.count - session.matchedQueryLength <= 3 {
            // «25.» ещё не дата, но станет: окно ждёт, спрятав пустой список.
            picker.update(items: [], matchedQueryLength: session.matchedQueryLength)
        } else {
            picker.close()
        }
    }

    /// Стрелки, Enter, Tab и Esc, пока окно открыто.
    func handleMentionPickerCommand(_ selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)), inlineAtoms.datePopover.handleCancel() { return true }
        let picker = mentionPicker
        guard picker.isOpen else { return false }
        // Пустой список: клавиши — тексту, Enter и Esc закрывают ожидание.
        guard !picker.visibleItems.isEmpty else {
            if [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))].contains(selector) { picker.close() }
            return false
        }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): picker.moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): picker.moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): picker.choose()
        case #selector(NSResponder.cancelOperation(_:)): picker.close()
        default: return false
        }
        return true
    }

    /// Выбор в окне: «@» или «[[» с набранным поиском заменяется одним знаком упоминания или даты.
    func insertAtom(for item: MentionPickerItem, replacingFrom location: Int) {
        let style: InlineStyle = switch item.target {
        case .page(let id): .mention(id)
        case .date(let date): .date(date)
        }
        let caret = selectedRange().location
        guard caret >= location, let position = mapper.blockPosition(at: location) else { return }
        insertAtom(style, in: NSRange(location: location, length: caret - location), blockAt: position.index)
        window?.makeFirstResponder(self)
    }

    /// Поставить атом на место `range` в блоке `index`: знак U+FFFC с оформлением и картинкой.
    func insertAtom(_ style: InlineStyle, in range: NSRange, blockAt index: Int) {
        let block = document.blocks[index]
        var attributes = PageTextStorageMapper.typingAttributes(for: block, after: mapper.previousKind(ofBlockAt: index), inline: [:])
        let typing = attributes
        attributes[.inlineAtom] = style
        attributes[.attachment] = InlineAtomAttachment.make(for: style)
        let atom = NSAttributedString(string: "\u{FFFC}", attributes: attributes)
        breakUndoCoalescing()
        guard replaceText(in: range, with: atom) else { return }
        setSelectedRange(NSRange(location: range.location + 1, length: 0))
        // Дальше набирается обычный текст, а не продолжение атома.
        typingAttributes = typing
        breakUndoCoalescing()
    }

    // MARK: Атомы на странице

    /// Вложение атома у знака `location`; `nil` — там не атом.
    func atomAttachment(at location: Int) -> InlineAtomAttachment? {
        guard let textStorage, location >= 0, location < textStorage.length else { return nil }
        return textStorage.attribute(.attachment, at: location, effectiveRange: nil) as? InlineAtomAttachment
    }

    /// Щелчок по атому у знака `index`: упоминание открывает страницу, дата — календарик. `true` — щелчок принят.
    @discardableResult
    func openAtom(atCharacter index: Int) -> Bool {
        guard let attachment = atomAttachment(at: index) else { return false }
        switch attachment.style {
        case .mention(let pageId):
            onOpenPage?(pageId)
            return true
        case .date(let date):
            inlineAtoms.datePopover.open(for: date, atCharacter: index, in: self)
            return true
        default:
            return false
        }
    }

    /// Атом под точкой (координаты окна текста).
    func openAtom(at point: NSPoint) -> Bool {
        let index = characterIndexForInsertion(at: point)
        for candidate in [index, index - 1] where candidate >= 0 {
            guard atomAttachment(at: candidate) != nil else { continue }
            let rect = firstRect(forCharacterRange: NSRange(location: candidate, length: 1), actualRange: nil)
            guard let window else { return openAtom(atCharacter: candidate) }
            let local = convert(window.convertFromScreen(rect), from: nil)
            if local.insetBy(dx: -1, dy: -1).contains(point) { return openAtom(atCharacter: candidate) }
        }
        return false
    }

    /// Справочник сменился: атомы видимой области раскладываются и рисуются заново.
    func redrawInlineAtoms() {
        guard let textStorage, textStorage.length > 0 else { return }
        var found = false
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, _, stop in
            if value is InlineAtomAttachment {
                found = true
                stop.pointee = true
            }
        }
        guard found, let textLayoutManager else { return }
        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        if window != nil { textLayoutManager.textViewportLayoutController.layoutViewport() }
        needsDisplay = true
    }

    /// Простой текст выделенного: упоминания — названием, даты — словами (data-model.md).
    func plainText(of range: NSRange) -> String {
        guard let textStorage else { return "" }
        let directory = mentionDirectory
        let pieces = NSMutableString()
        textStorage.enumerateAttribute(.inlineAtom, in: range) { value, run, _ in
            let text = (textStorage.string as NSString).substring(with: run)
            if let style = value as? InlineStyle, style.isAtom {
                let atoms = InlineText(text, runs: (0..<run.length).map { StyledRun(start: $0, length: 1, style: style) })
                pieces.append(atoms.plainText(pageTitle: directory.plainTitle(of:), calendar: calendar))
            } else {
                pieces.append(text)
            }
        }
        return pieces as String
    }
}

// MARK: Окно

/// Окно без рамки под «@», как меню «/»: строки «иконка + название + путь», над разделами — заголовки.
final class MentionPickerWindow: NSPanel {
    let pickerView = MentionPickerView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        contentView = pickerView
        setAccessibilityIdentifier("mention-picker")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(below anchor: NSRect, parent: NSWindow) {
        let size = pickerView.fittingMenuSize
        let margin = PopupMenuWindow.shadowMargin
        let spacing = Metrics.PopupMenu.anchorSpacing
        var origin = NSPoint(x: anchor.minX - margin, y: anchor.minY - spacing - size.height - margin)
        if let screen = parent.screen?.visibleFrame, origin.y + margin < screen.minY {
            origin.y = anchor.maxY + spacing - margin
        }
        setFrame(NSRect(x: origin.x, y: origin.y, width: size.width + 2 * margin, height: size.height + 2 * margin), display: true)
        PopupWindows.show(self, over: parent)
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

@MainActor
final class MentionPickerView: NSView {
    private(set) var items: [MentionPickerItem] = []
    private(set) var selectedIndex = 0
    private var rows: [MentionPickerRowView] = []
    var onChoose: ((MentionPickerItem) -> Void)?

    static let width: CGFloat = 324

    override var isFlipped: Bool { true }

    /// Заголовки разделов «Страницы» и «Даты» и где они стоят (номер первой строки раздела).
    private var sections: [(title: String, firstRow: Int)] {
        var result: [(String, Int)] = []
        for (index, item) in items.enumerated() {
            let title = item.pageId == nil ? "Дата" : "Упомянуть страницу"
            if result.last?.0 != title { result.append((title, index)) }
        }
        return result
    }

    var fittingMenuSize: NSSize {
        let height = Metrics.PopupMenu.verticalPadding * 2 + CGFloat(sections.count) * Metrics.PopupMenu.sectionHeaderHeight
            + CGFloat(items.count) * Metrics.PopupMenu.rowHeight
        return NSSize(width: Self.width, height: height)
    }

    private var menuRect: NSRect {
        let margin = PopupMenuWindow.shadowMargin
        return NSRect(x: margin, y: margin, width: Self.width, height: fittingMenuSize.height)
    }

    func setItems(_ items: [MentionPickerItem]) {
        guard items != self.items else { return }
        self.items = items
        selectedIndex = 0
        rows.forEach { $0.removeFromSuperview() }
        rows = items.enumerated().map { index, item in
            let row = MentionPickerRowView(item: item)
            row.onHover = { [weak self] in self?.select(index) }
            row.onClick = { [weak self] in self?.onChoose?(item) }
            addSubview(row)
            return row
        }
        layoutRows()
        select(0)
        needsDisplay = true
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        select((selectedIndex + delta + items.count) % items.count)
    }

    var selectedItem: MentionPickerItem? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    private func select(_ index: Int) {
        selectedIndex = index
        for (position, row) in rows.enumerated() { row.isSelected = position == index }
    }

    private func rowTop(_ index: Int) -> CGFloat {
        let headers = sections.filter { $0.firstRow <= index }.count
        return menuRect.minY + Metrics.PopupMenu.verticalPadding + CGFloat(headers) * Metrics.PopupMenu.sectionHeaderHeight
            + CGFloat(index) * Metrics.PopupMenu.rowHeight
    }

    private func layoutRows() {
        let inset = Metrics.PopupMenu.rowInset
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: menuRect.minX + inset, y: rowTop(index), width: menuRect.width - 2 * inset, height: Metrics.PopupMenu.rowHeight)
        }
    }

    override func layout() {
        super.layout()
        layoutRows()
    }

    override func draw(_ dirtyRect: NSRect) {
        PopupSurface.draw(card: menuRect)
        let style = Typography.popupMenuSectionHeader
        let x = menuRect.minX + Metrics.PopupMenu.rowInset + Metrics.PopupMenu.rowHorizontalPadding
        for section in sections {
            let top = rowTop(section.firstRow) - Metrics.PopupMenu.sectionHeaderHeight
                + (Metrics.PopupMenu.sectionHeaderHeight - style.lineHeight) / 2
            NSAttributedString(string: section.title, attributes: [.font: style.font, .foregroundColor: Palette.textSecondary])
                .draw(in: NSRect(x: x, y: top, width: menuRect.maxX - x, height: style.lineHeight))
        }
    }
}

@MainActor
final class MentionPickerRowView: NSView {
    let item: MentionPickerItem
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?

    init(item: MentionPickerItem) {
        self.item = item
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
        setAccessibilityIdentifier(item.identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected { PopupMenuRowView.drawHighlight(in: bounds) }
        let padding = Metrics.PopupMenu.rowHorizontalPadding
        let iconSize = Metrics.PopupMenu.iconSize
        let iconRect = NSRect(x: padding, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        switch item.target {
        case .page:
            if let icon = item.icon, !icon.isEmpty {
                let string = NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: iconSize * 0.8)])
                let size = string.size()
                string.draw(at: NSPoint(x: iconRect.midX - size.width / 2, y: iconRect.midY - size.height / 2))
            } else {
                DocumentGlyph.image(size: Metrics.PopupMenu.iconInkSize, color: Palette.textSecondary)
                    .draw(in: iconRect.insetBy(dx: 2, dy: 2), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        case .date:
            PopupMenuRowView.drawIcon(.symbol("calendar"), color: Palette.textPrimary, in: iconRect)
        }
        let textX = iconRect.maxX + Metrics.PopupMenu.iconToTitleSpacing
        let titleStyle = Typography.popupMenuTitle
        let title = NSMutableAttributedString(string: item.title, attributes: [.font: titleStyle.font, .foregroundColor: Palette.textPrimary])
        if !item.path.isEmpty {
            title.append(NSAttributedString(string: "  " + item.path.joined(separator: " / "), attributes: [
                .font: Typography.popupMenuShortcut.font, .foregroundColor: Palette.textSecondary,
            ]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
        title.draw(in: NSRect(x: textX, y: (bounds.height - titleStyle.lineHeight) / 2, width: bounds.maxX - padding - textX,
                              height: titleStyle.lineHeight))
    }
}
