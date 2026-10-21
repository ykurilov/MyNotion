import AppKit
import Databases
import NotesCore
import VisualStyle

/// Связь в сетке: названия строк цели плашками (`CellPresentation.chips`); правка — окно связи под ячейкой.
struct RelationCell: GridCellType {
    let kind = PropertyKind.relation
}

/// Окно ячейки связи (contracts/database-ui.md, `notion-relation-picker.png`, `notion-relation-picker-selected.png`):
/// поле «Найти или создать страницу…» и справа «В <база>»; «N выбрано» — связанные строки с «−»; «Выбрать ещё» —
/// строки базы-цели по поиску; текст, которого нет среди строк, — «+ Создать «текст»» (строка в базе-цели и связь).
/// Стрелки двигают подсветку, Enter выбирает, Esc закрывает. Каждая правка — шаг ⌘Z.
@MainActor
final class RelationCellView: NSView, CellPopupContent {
    nonisolated static let factory = CellPopupFactory(kinds: [.relation]) { RelationCellView(context: $0) }
    static let width: CGFloat = 360
    static let maxHeight: CGFloat = 400

    enum Entry: Equatable {
        case selected(RelatedRow)
        case candidate(RelatedRow)
        case create(String)
    }

    private let context: CellPopupContext
    private let search: PropertyPopupField
    private let databaseLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let list = FlippedList()
    private(set) var entries: [Entry] = []
    private var rows: [NSView] = []
    private var highlighted: Int?
    private var query = ""

    init(context: CellPopupContext) {
        self.context = context
        search = PropertyPopupField(text: context.initialText ?? "", placeholder: "Найти или создать страницу…", searchGlyph: true,
                                    identifier: "relation-picker-search")
        query = context.initialText ?? ""
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        setAccessibilityIdentifier("relation-picker")
        addSubview(search)
        databaseLabel.font = Typography.popupMenuTitle.font
        databaseLabel.textColor = Palette.textSecondary
        databaseLabel.lineBreakMode = .byTruncatingTail
        databaseLabel.alignment = .right
        addSubview(databaseLabel)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        addSubview(scroll)
        search.onChange = { [weak self] text in
            self?.query = text
            self?.reloadEntries()
        }
        search.onCommand = { [weak self] command in self?.handle(command) ?? false }
        reloadEntries()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var relation: DatabaseProperty? {
        try? DatabaseCatalog.read(context.controller.databaseId, in: context.store).propertiesById[context.propertyId]
    }

    // MARK: Список

    /// Строки окна: выбранные, затем остальные строки цели по поиску; «Создать», если такой строки нет.
    func reloadEntries() {
        guard let relation else { return }
        let selected = (try? RelationLinks.related(context.rowId, through: relation, in: context.store)) ?? []
        let chosen = Set(selected.map(\.id))
        let candidates = ((try? RelationLinks.candidates(for: relation, matching: query, in: context.store)) ?? []).filter { !chosen.contains($0.id) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = SortableText.make(trimmed)
        let shownSelected = key.isEmpty ? selected : selected.filter { SortableText.make($0.title).contains(key) }
        entries = shownSelected.map(Entry.selected) + candidates.map(Entry.candidate)
        if !trimmed.isEmpty, !(selected + candidates).contains(where: { SortableText.make($0.title) == key }) {
            entries.append(.create(trimmed))
        }
        if case .available(let title)? = try? RelationLinks.targetState(of: relation, in: context.store) {
            databaseLabel.stringValue = "В «\(title.isEmpty ? Page.untitledTitle : title)»"
        }
        highlighted = entries.isEmpty ? nil : min(highlighted ?? 0, entries.count - 1)
        if !trimmed.isEmpty, let first = entries.firstIndex(where: { if case .selected = $0 { return false } else { return true } }) {
            highlighted = first
        }
        rebuildRows(selectedCount: selected.count)
        needsLayout = true
        context.resize()
    }

    private func rebuildRows(selectedCount: Int) {
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        var lastSection: String?
        for (index, entry) in entries.enumerated() {
            let section: String? = switch entry {
            case .selected: "\(selectedCount) выбрано"
            case .candidate, .create: selectedCount > 0 ? "Выбрать ещё" : nil
            }
            if let section, section != lastSection {
                let caption = PropertyPopupCaption(section)
                list.addSubview(caption)
                rows.append(caption)
            }
            lastSection = section
            let row: ChoiceRow
            switch entry {
            case .selected(let related), .candidate(let related):
                row = ChoiceRow(title: related.title.isEmpty ? Page.untitledTitle : related.title, icon: related.icon == nil ? "doc" : nil,
                                identifier: "relation-picker-row-\(related.id.uuidString.lowercased())")
            case .create(let title):
                row = ChoiceRow(title: "Создать «\(title)»", icon: "plus", identifier: "relation-picker-create")
            }
            row.isHighlighted = index == highlighted
            row.onPress = { [weak self] in self?.choose(index) }
            list.addSubview(row)
            rows.append(row)
            if case .selected(let related) = entry {
                let remove = NSButton(title: "−", target: self, action: #selector(removeTapped(_:)))
                remove.bezelStyle = .smallSquare
                remove.isBordered = true
                remove.tag = index
                remove.setAccessibilityIdentifier("relation-picker-remove-\(related.id.uuidString.lowercased())")
                remove.setAccessibilityLabel("Убрать связь с «\(related.title)»")
                row.addSubview(remove)
            }
        }
    }

    private var listHeight: CGFloat {
        rows.reduce(2 * Metrics.PopupMenu.verticalPadding) { $0 + ($1 is PropertyPopupCaption ? PropertyPopupMetrics.captionHeight : PropertyPopupMetrics.rowHeight) }
    }

    var preferredSize: NSSize {
        NSSize(width: Self.width, height: min(Self.maxHeight, PropertyPopupMetrics.searchBlockHeight + max(listHeight, PropertyPopupMetrics.rowHeight)))
    }

    override var fittingSize: NSSize { preferredSize }

    func focusFirstField() { search.focus() }

    override func layout() {
        super.layout()
        let inset = PropertyPopupMetrics.inset
        let labelWidth: CGFloat = 120
        search.frame = NSRect(x: inset, y: 4, width: bounds.width - 2 * inset - labelWidth - 4, height: PropertyPopupMetrics.searchBlockHeight - 4)
        databaseLabel.frame = NSRect(x: bounds.width - inset - labelWidth, y: 12, width: labelWidth - PropertyPopupMetrics.padding, height: 18)
        scroll.frame = NSRect(x: 0, y: PropertyPopupMetrics.searchBlockHeight, width: bounds.width, height: bounds.height - PropertyPopupMetrics.searchBlockHeight)
        list.frame = NSRect(x: 0, y: 0, width: bounds.width, height: listHeight)
        var y = Metrics.PopupMenu.verticalPadding
        for row in rows {
            let height = row is PropertyPopupCaption ? PropertyPopupMetrics.captionHeight : PropertyPopupMetrics.rowHeight
            row.frame = NSRect(x: inset, y: y, width: bounds.width - 2 * inset, height: height)
            if let remove = row.subviews.compactMap({ $0 as? NSButton }).first {
                remove.frame = NSRect(x: row.bounds.width - 28, y: (min(height, Metrics.ActionMenu.highlightHeight) - 20) / 2, width: 22, height: 20)
            }
            y += height
        }
    }

    // MARK: Правки

    private func choose(_ index: Int) {
        guard let entry = entries[safe: index] else { return }
        switch entry {
        case .selected:
            // Связанная строка: снимается кнопкой «−».
            return
        case .candidate(let related):
            context.attempt { try context.operations.linkRow(context.rowId, through: context.propertyId, to: related.id) }
            afterEdit()
        case .create(let title):
            context.attempt { _ = try context.operations.createLinkedRow(for: context.rowId, through: context.propertyId, title: title) }
            afterEdit()
        }
    }

    @objc private func removeTapped(_ sender: NSButton) {
        guard case .selected(let related)? = entries[safe: sender.tag] else { return }
        context.attempt { try context.operations.unlinkRow(context.rowId, through: context.propertyId, from: related.id) }
        reloadEntries()
    }

    /// После выбора: лимит «1 страница» — окно закрывается (как Notion), иначе поиск очищается и список обновляется.
    private func afterEdit() {
        if relation?.relationLimit == .one {
            context.close()
            return
        }
        query = ""
        search.field.stringValue = ""
        reloadEntries()
    }

    private func handle(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !entries.isEmpty else { return true }
            let step = command == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            highlighted = ((highlighted ?? -step) + step + entries.count) % entries.count
            for case let row as ChoiceRow in rows { row.isHighlighted = false }
            if let highlighted, let row = choiceRow(at: highlighted) {
                row.isHighlighted = true
                list.scrollToVisible(row.frame)
            }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let highlighted { choose(highlighted) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            context.close()
            return true
        default:
            return false
        }
    }

    private func choiceRow(at index: Int) -> ChoiceRow? {
        rows.compactMap { $0 as? ChoiceRow }[safe: index]
    }

    private final class FlippedList: NSView {
        override var isFlipped: Bool { true }
    }
}
