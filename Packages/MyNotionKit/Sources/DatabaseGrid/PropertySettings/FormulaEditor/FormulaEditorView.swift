import AppKit
import Databases
import Formulas
import NotesCore
import VisualStyle

/// Окно «Изменить формулу» как у Notion 7.39 (`notion-formula-editor*.png`, contracts/formulas.md, «Редактор»):
/// заголовок с «Готово», поле формулы с подсветкой и плашками свойств, «Предпросмотр с <строка ▾>», итог и «Тип: …»,
/// ошибка по-русски с подчёркиванием места; снизу — список «Свойства», «Встроенные» и функции по разделам с поиском по
/// набранному слову, справа — описание выбранного с примерами. Enter в списке — вставить, ⌘Enter — «Готово», Esc — закрыть.
@MainActor
public final class FormulaEditorView: NSView, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public static let size = NSSize(width: 600, height: 470)

    public let model: FormulaEditorModel
    /// «Готово» — формула записана; закрыть окно.
    public var onDone: (() -> Void)?
    public var onClose: (() -> Void)?
    /// Запись формулы (операция с ⌘Z окна); по умолчанию — новая без отмены.
    public var operations: DatabaseOperations

    let field = FormulaTextView()
    private let fieldScroll = NSScrollView()
    private let fieldFrame = NSView()
    private let titleLabel = NSTextField(labelWithString: "Изменить формулу")
    private let discardButton = NSButton(title: "Отменить изменения", target: nil, action: nil)
    let doneButton = NSButton(title: "Готово", target: nil, action: nil)
    private let closeButton = NSButton()
    private let previewLabel = NSTextField(labelWithString: "Предпросмотр с")
    let previewRowButton = NSPopUpButton(frame: .zero, pullsDown: false)
    let outputLabel = NSTextField(wrappingLabelWithString: "")
    let typeLabel = NSTextField(labelWithString: "")
    private let typeChip = NSView()
    private let divider = NSView()
    let list = NSTableView()
    private let listScroll = NSScrollView()
    let descriptionView = FormulaDescriptionView()
    private var rows: [ListRow] = []
    private var isApplying = false
    static let fieldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    enum ListRow: Hashable {
        case header(String)
        case item(FormulaEditorModel.Item)
    }

    public init(model: FormulaEditorModel, operations: DatabaseOperations) {
        self.model = model
        self.operations = operations
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        build()
        setFieldText(model.text)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public override var isFlipped: Bool { true }

    // MARK: Сборка

    private func build() {
        setAccessibilityIdentifier("formula-editor")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = Palette.textPrimary
        titleLabel.frame = NSRect(x: 16, y: 14, width: 260, height: 20)

        discardButton.isBordered = false
        discardButton.contentTintColor = Palette.textSecondary
        discardButton.font = .systemFont(ofSize: 13)
        discardButton.target = self
        discardButton.action = #selector(discardChanges)
        discardButton.setAccessibilityIdentifier("formula-discard")
        discardButton.frame = NSRect(x: Self.size.width - 300, y: 12, width: 150, height: 24)

        doneButton.bezelStyle = .push
        doneButton.controlSize = .small
        doneButton.bezelColor = Palette.primaryButtonFill
        doneButton.keyEquivalent = "\r"
        doneButton.keyEquivalentModifierMask = [.command]
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.setAccessibilityIdentifier("formula-done")
        doneButton.frame = NSRect(x: Self.size.width - 136, y: 11, width: 84, height: 26)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Закрыть")
        closeButton.isBordered = false
        closeButton.contentTintColor = Palette.textSecondary
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.setAccessibilityIdentifier("formula-close")
        closeButton.frame = NSRect(x: Self.size.width - 40, y: 12, width: 24, height: 24)

        fieldFrame.wantsLayer = true
        fieldFrame.layer?.cornerRadius = 8
        fieldFrame.layer?.borderWidth = 1
        fieldFrame.frame = NSRect(x: 16, y: 48, width: Self.size.width - 32, height: 84)
        fieldScroll.frame = fieldFrame.bounds.insetBy(dx: 2, dy: 2)
        fieldScroll.autoresizingMask = [.width, .height]
        fieldScroll.drawsBackground = false
        fieldScroll.hasVerticalScroller = true
        fieldScroll.autohidesScrollers = true
        field.frame = NSRect(origin: .zero, size: fieldScroll.contentSize)
        field.autoresizingMask = [.width]
        field.isRichText = true
        field.importsGraphics = false
        field.allowsUndo = true
        field.drawsBackground = false
        field.font = Self.fieldFont
        field.textColor = Palette.textPrimary
        field.textContainerInset = NSSize(width: 6, height: 8)
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.isAutomaticTextReplacementEnabled = false
        field.isAutomaticSpellingCorrectionEnabled = false
        field.isContinuousSpellCheckingEnabled = false
        field.isGrammarCheckingEnabled = false
        field.delegate = self
        field.setAccessibilityIdentifier("formula-field")
        field.onFocusChange = { [weak self] _ in self?.updateFieldBorder() }
        fieldScroll.documentView = field
        fieldFrame.addSubview(fieldScroll)

        previewLabel.font = .systemFont(ofSize: 12)
        previewLabel.textColor = Palette.textSecondary
        previewLabel.frame = NSRect(x: 16, y: 146, width: 104, height: 18)
        previewLabel.sizeToFit()
        previewRowButton.isBordered = false
        previewRowButton.font = .systemFont(ofSize: 12)
        previewRowButton.target = self
        previewRowButton.action = #selector(previewRowChanged)
        previewRowButton.setAccessibilityIdentifier("formula-preview-row")
        for row in model.previewRows {
            previewRowButton.addItem(withTitle: row.title)
            previewRowButton.lastItem?.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            previewRowButton.lastItem?.representedObject = row.id
        }
        if model.previewRows.isEmpty { previewRowButton.addItem(withTitle: "Строк нет"); previewRowButton.isEnabled = false }
        previewRowButton.frame = NSRect(x: 16 + previewLabel.frame.width + 2, y: 141, width: 240, height: 26)

        typeChip.wantsLayer = true
        typeChip.layer?.cornerRadius = 4
        typeLabel.font = .systemFont(ofSize: 11)
        typeLabel.textColor = Palette.textSecondary
        typeLabel.setAccessibilityIdentifier("formula-type")
        typeChip.addSubview(typeLabel)

        outputLabel.font = .systemFont(ofSize: 14)
        outputLabel.maximumNumberOfLines = 3
        outputLabel.lineBreakMode = .byTruncatingTail
        outputLabel.setAccessibilityIdentifier("formula-output")
        outputLabel.frame = NSRect(x: 16, y: 172, width: Self.size.width - 140, height: 40)

        divider.wantsLayer = true
        divider.frame = NSRect(x: 0, y: 220, width: Self.size.width, height: 1)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.width = 200
        list.addTableColumn(column)
        list.headerView = nil
        list.rowHeight = 28
        list.intercellSpacing = .zero
        list.backgroundColor = .clear
        list.style = .plain
        list.selectionHighlightStyle = .regular
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(insertSelected)
        list.refusesFirstResponder = true
        list.setAccessibilityIdentifier("formula-list")
        listScroll.documentView = list
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.frame = NSRect(x: 8, y: 226, width: 210, height: Self.size.height - 234)

        descriptionView.frame = NSRect(x: 230, y: 232, width: Self.size.width - 246, height: Self.size.height - 244)
        descriptionView.setAccessibilityIdentifier("formula-description")

        for view in [titleLabel, discardButton, doneButton, closeButton, fieldFrame, previewLabel, previewRowButton, typeChip, outputLabel,
                     divider, listScroll, descriptionView] as [NSView] { addSubview(view) }
        updateColors()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
        setFieldText(model.text)
        refresh()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            typeChip.layer?.backgroundColor = Palette.inlineCodeBackground.cgColor
            divider.layer?.backgroundColor = Palette.popupDivider.cgColor
            updateFieldBorder()
        }
    }

    private func updateFieldBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let focused = window?.firstResponder === field
            fieldFrame.layer?.borderColor = (focused ? Palette.focusRing : Palette.searchFieldBorder).cgColor
            fieldFrame.layer?.borderWidth = focused ? 1.5 : 1
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        Palette.popupMenuBackground.setFill()
        dirtyRect.fill()
    }

    /// Поле получает фокус, каретка — в конце.
    public func focusField() {
        window?.makeFirstResponder(field)
        field.setSelectedRange(NSRange(location: field.string.utf16.count, length: 0))
        updateFieldBorder()
    }

    /// Заменить текст поля, как если бы его набрали (галерея, сценарии проверки).
    public func type(_ text: String) {
        field.insertText(text, replacementRange: NSRange(location: 0, length: field.string.utf16.count))
    }

    // MARK: Поле и плашки

    /// Записать текст формулы в поле: `prop("…")` найденных свойств — плашками.
    private func setFieldText(_ text: String) {
        isApplying = true
        defer { isApplying = false }
        let attributed = NSMutableAttributedString(string: text, attributes: baseAttributes)
        field.textStorage?.setAttributedString(attributed)
        convertChips()
        applyHighlighting()
    }

    private var baseAttributes: [NSAttributedString.Key: Any] { [.font: Self.fieldFont, .foregroundColor: Palette.textPrimary] }

    /// Готовые `prop("…")` — в плашки (отменяются ⌘Z вместе с набором).
    private func convertChips() {
        guard let storage = field.textStorage else { return }
        var mapping = FormulaFieldText(storage)
        let pending = model.propertyChips.filter { chip in
            let range = mapping.fieldRange(chip.range)
            return !(range.length == 1 && storage.attribute(.attachment, at: range.location, effectiveRange: nil) is FormulaChipAttachment)
        }
        guard !pending.isEmpty else { return }
        let caret = mapping.formulaOffset(field.selectedRange().location)
        for chip in pending.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let range = mapping.fieldRange(chip.range)
            let attachment = FormulaChipAttachment(property: chip.property, kind: chip.kind, font: Self.fieldFont)
            let replacement = NSMutableAttributedString(attachment: attachment)
            replacement.addAttributes(baseAttributes, range: NSRange(location: 0, length: replacement.length))
            if field.shouldChangeText(in: range, replacementString: replacement.string) {
                storage.replaceCharacters(in: range, with: replacement)
                field.didChangeText()
            }
        }
        mapping = FormulaFieldText(storage)
        field.setSelectedRange(NSRange(location: mapping.fieldLocation(caret), length: 0))
    }

    /// Цвета: функции, тексты, числа, слова языка; ошибка — красным подчёркиванием.
    private func applyHighlighting() {
        guard let storage = field.textStorage else { return }
        let mapping = FormulaFieldText(storage)
        storage.beginEditing()
        let whole = NSRange(location: 0, length: storage.length)
        // Плашки — вложения: их не снимать, только цвет и подчёркивание.
        storage.addAttributes(baseAttributes, range: whole)
        storage.removeAttribute(.underlineStyle, range: whole)
        storage.removeAttribute(.underlineColor, range: whole)
        for span in FormulaHighlight.spans(mapping.text) {
            let color: NSColor? = switch span.kind {
            case .function: Palette.notionText(.blue)
            case .text: Palette.notionText(.green)
            case .number: Palette.notionText(.red)
            case .keyword: Palette.notionText(.purple)
            case .variable: Palette.notionText(.orange)
            case .symbol: nil
            }
            guard let color else { continue }
            let range = mapping.fieldRange(span.range)
            guard range.length > 0, !(storage.attribute(.attachment, at: range.location, effectiveRange: nil) is FormulaChipAttachment) else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
        if let error = model.error, let range = error.range {
            var field = mapping.fieldRange(range)
            if field.length == 0 { field = NSRange(location: max(0, min(field.location, storage.length - 1)), length: storage.length > 0 ? 1 : 0) }
            if field.length > 0 {
                storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                       .underlineColor: Palette.destructiveText], range: field)
            }
        }
        storage.endEditing()
        field.typingAttributes = baseAttributes
    }

    public func textDidChange(_ notification: Notification) {
        guard !isApplying, let storage = field.textStorage else { return }
        isApplying = true
        defer { isApplying = false }
        var mapping = FormulaFieldText(storage)
        model.edit(mapping.text, caret: mapping.formulaOffset(field.selectedRange().location))
        convertChips()
        mapping = FormulaFieldText(storage)
        if mapping.text != model.text { model.edit(mapping.text, caret: mapping.formulaOffset(field.selectedRange().location)) }
        applyHighlighting()
        refresh()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard !isApplying, let storage = field.textStorage else { return }
        model.moveCaret(FormulaFieldText(storage).formulaOffset(field.selectedRange().location))
        reloadList()
    }

    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        case #selector(NSResponder.moveDown(_:)) where !model.searchWord.isEmpty:
            moveSelection(1)
            return true
        case #selector(NSResponder.moveUp(_:)) where !model.searchWord.isEmpty:
            moveSelection(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)) where !model.searchWord.isEmpty && model.selected != nil:
            insertSelected()
            return true
        case #selector(NSResponder.insertTab(_:)) where model.selected != nil:
            insertSelected()
            return true
        default:
            return false
        }
    }

    // MARK: Итог, тип, ошибка

    private func refresh() {
        discardButton.isHidden = !model.isChanged
        doneButton.isEnabled = model.canSave
        typeLabel.stringValue = model.typeLabel
        typeLabel.sizeToFit()
        let chipSize = NSSize(width: typeLabel.frame.width + 12, height: 18)
        typeChip.frame = NSRect(x: Self.size.width - 16 - chipSize.width, y: 174, width: chipSize.width, height: chipSize.height)
        typeLabel.frame.origin = NSPoint(x: 6, y: 1)
        if let error = model.error {
            outputLabel.stringValue = error.message
            outputLabel.textColor = Palette.destructiveText
            outputLabel.font = .systemFont(ofSize: 13)
        } else {
            outputLabel.stringValue = model.outputText
            outputLabel.textColor = model.outputText == "Нет итога" ? Palette.textSecondary : Palette.textPrimary
            outputLabel.font = .systemFont(ofSize: 14)
        }
        reloadList()
    }

    private func reloadList() {
        rows = model.sections.flatMap { [ListRow.header($0.title)] + $0.items.map(ListRow.item) }
        list.reloadData()
        if let selected = model.selected, let index = rows.firstIndex(of: .item(selected)) {
            list.selectRowIndexes([index], byExtendingSelection: false)
            list.scrollRowToVisible(index)
        }
        descriptionView.show(model.selected.map(model.description(of:)))
    }

    private func moveSelection(_ step: Int) {
        let items = rows.compactMap { if case .item(let item) = $0 { item } else { nil } }
        guard !items.isEmpty else { return }
        let current = model.selected.flatMap { items.firstIndex(of: $0) } ?? -1
        model.selected = items[max(0, min(items.count - 1, current + step))]
        reloadList()
    }

    @objc private func insertSelected() {
        if list.clickedRow >= 0, case .item(let item) = rows[list.clickedRow] { model.selected = item }
        guard let item = model.selected, let storage = field.textStorage else { return }
        let mapping = FormulaFieldText(storage)
        let word = FormulaHighlight.word(before: model.caret, in: model.text)
        let insertion = model.insertion(for: item)
        window?.makeFirstResponder(field)
        field.insertText(insertion.text, replacementRange: mapping.fieldRange(word.range))
        let after = FormulaFieldText(storage)
        field.setSelectedRange(NSRange(location: after.fieldLocation(word.range.lowerBound + insertion.caretShift), length: 0))
    }

    // MARK: Кнопки

    @objc private func previewRowChanged() {
        guard let id = previewRowButton.selectedItem?.representedObject as? UUID else { return }
        model.previewRow = model.previewRows.first { $0.id == id }
        refresh()
    }

    @objc private func discardChanges() {
        setFieldText(model.originalText)
        model.edit(model.originalText, caret: model.originalText.count)
        refresh()
    }

    @objc func done() {
        guard model.canSave else { return }
        do {
            try model.save(using: operations)
            onDone?()
        } catch let error as FormulaError {
            outputLabel.stringValue = error.message
            outputLabel.textColor = Palette.destructiveText
        } catch {
            outputLabel.stringValue = error.localizedDescription
            outputLabel.textColor = Palette.destructiveText
        }
    }

    @objc private func close() { onClose?() }

    // MARK: Список

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .header = rows[row] { true } else { false } }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .item = rows[row] { true } else { false } }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .header = rows[row] { 30 } else { 28 } }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        cell.addSubview(label)
        switch rows[row] {
        case .header(let title):
            label.stringValue = title
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = Palette.textSecondary
            label.frame = NSRect(x: 8, y: 6, width: 190, height: 16)
        case .item(let item):
            label.stringValue = item.title
            label.font = .systemFont(ofSize: 14)
            label.textColor = Palette.textPrimary
            label.frame = NSRect(x: 32, y: 5, width: 166, height: 18)
            let icon = NSImageView(frame: NSRect(x: 8, y: 6, width: 16, height: 16))
            icon.image = NSImage(systemSymbolName: Self.symbol(of: item), accessibilityDescription: nil)
            icon.contentTintColor = Palette.textSecondary
            cell.addSubview(icon)
            cell.setAccessibilityIdentifier("formula-item-\(item.title)")
        }
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard list.selectedRow >= 0, case .item(let item) = rows[list.selectedRow], item != model.selected else { return }
        model.selected = item
        descriptionView.show(model.description(of: item))
    }

    static func symbol(of item: FormulaEditorModel.Item) -> String {
        switch item {
        case .property(_, let kind): CellKind.for(kind).symbol
        case .builtin(let symbol): ["true", "false", "and", "or", "not", ">", ">=", "<", "<=", "==", "!="].contains(symbol) ? "checkmark.square" : "number"
        case .function(let name):
            switch FormulaFunctionCatalog.byName[name]?.section {
            case .logic?: "checkmark.square"
            case .numbers?: "number"
            case .text?: "textformat"
            case .dates?: "calendar"
            case .lists?: "list.bullet"
            default: "function"
            }
        }
    }
}

/// Описание пункта справа: заголовок (синтаксис), текст и примеры в рамках с итогом «= …».
@MainActor
public final class FormulaDescriptionView: NSView {
    private var labels: [NSView] = []
    public private(set) var shown: FormulaEditorModel.Description?

    public override var isFlipped: Bool { true }

    func show(_ description: FormulaEditorModel.Description?) {
        guard description != shown else { return }
        shown = description
        labels.forEach { $0.removeFromSuperview() }
        labels = []
        guard let description else { return }
        var y: CGFloat = 0
        let width = bounds.width
        let title = NSTextField(wrappingLabelWithString: description.title)
        title.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        title.textColor = Palette.textPrimary
        title.frame = NSRect(x: 0, y: y, width: width, height: title.sizeThatFits(NSSize(width: width, height: 200)).height)
        title.setAccessibilityIdentifier("formula-description-title")
        y = title.frame.maxY + 6
        let summary = NSTextField(wrappingLabelWithString: description.summary)
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = Palette.textSecondary
        summary.frame = NSRect(x: 0, y: y, width: width, height: summary.sizeThatFits(NSSize(width: width, height: 200)).height)
        y = summary.frame.maxY + 10
        labels = [title, summary]
        for example in description.examples.prefix(3) {
            let box = FormulaExampleBox(example: example, width: width)
            box.frame.origin = NSPoint(x: 0, y: y)
            y = box.frame.maxY + 8
            labels.append(box)
        }
        labels.forEach(addSubview)
    }
}

/// Пример в рамке: формула и «= итог».
final class FormulaExampleBox: NSView {
    init(example: FormulaExample, width: CGFloat) {
        let formula = NSTextField(wrappingLabelWithString: example.formula)
        formula.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        formula.textColor = Palette.notionText(.blue)
        let formulaHeight = formula.sizeThatFits(NSSize(width: width - 20, height: 200)).height
        let result = NSTextField(labelWithString: example.result.isEmpty ? "" : "= " + example.result)
        result.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        result.textColor = Palette.textPrimary
        let height = formulaHeight + (example.result.isEmpty ? 14 : 34)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        formula.frame = NSRect(x: 10, y: 7, width: width - 20, height: formulaHeight)
        result.frame = NSRect(x: 10, y: formulaHeight + 10, width: width - 20, height: 18)
        addSubview(formula)
        if !example.result.isEmpty { addSubview(result) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func updateLayer() {
        layer?.borderColor = Palette.border.cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}
