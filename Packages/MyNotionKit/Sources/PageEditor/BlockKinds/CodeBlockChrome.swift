import AppKit
import CodeHighlighting
import VisualStyle

/// Окно выбора языка блока кода (contracts/blocks-and-keys.md, «Блок кода»): поле поиска и список 24 языков
/// и «Простого текста»; набор сужает список, ↑↓ выбирают, Enter — готово, Esc — закрыть.
@MainActor
final class CodeLanguagePicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSPopoverDelegate {
    static let shared = CodeLanguagePicker()

    private let popover = NSPopover()
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private var shown: [LanguageDefinition] = LanguageDefinition.all
    private var onChoose: ((String) -> Void)?

    private override init() {
        super.init()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
        searchField.placeholderString = "Поиск языка"
        searchField.delegate = self
        searchField.frame = NSRect(x: 8, y: 268, width: 204, height: 24)
        searchField.setAccessibilityIdentifier("code-language-search")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setAccessibilityIdentifier("code-language-list")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 262))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        content.addSubview(searchField)
        content.addSubview(scroll)
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    func show(below anchor: NSView, selected: String?, onChoose: @escaping (String) -> Void) {
        self.onChoose = onChoose
        searchField.stringValue = ""
        filter("")
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(searchField)
        if let index = shown.firstIndex(where: { $0.id == (selected ?? LanguageDefinition.plain.id) }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
    }

    /// Языки, у которых название или имя начинается с набранного (каждое слово — начало слова, как в меню «/»).
    static func matching(_ query: String) -> [LanguageDefinition] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return LanguageDefinition.all }
        return LanguageDefinition.all.filter { language in
            ([language.title, language.id] + language.aliases).contains { name in
                name.lowercased().split(whereSeparator: { $0 == " " || $0 == "/" }).contains { $0.hasPrefix(query) }
                    || name.lowercased().hasPrefix(query)
            }
        }
    }

    func choose(_ id: String) {
        popover.close()
        onChoose?(id)
        onChoose = nil
    }

    private func filter(_ query: String) {
        shown = Self.matching(query)
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0, table.clickedRow < shown.count else { return }
        choose(shown[table.clickedRow].id)
    }

    func controlTextDidChange(_ obj: Notification) {
        filter(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            let step = selector == #selector(NSResponder.moveUp(_:)) ? -1 : 1
            let row = min(max(0, table.selectedRow + step), shown.count - 1)
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if table.selectedRow >= 0, table.selectedRow < shown.count { choose(shown[table.selectedRow].id) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            popover.close()
            return true
        default:
            return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: shown[row].title)
        label.font = Typography.popupMenuTitle.font
        label.textColor = Palette.textPrimary
        label.setAccessibilityIdentifier("code-language-\(shown[row].id)")
        return label
    }
}
