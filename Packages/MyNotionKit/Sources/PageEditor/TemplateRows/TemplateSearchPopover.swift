import AppKit
import VisualStyle

/// «Ещё шаблоны…»: поиск по названиям всех шаблонов. ↑↓ меняют строку, Enter выбирает, Esc закрывает.
@MainActor
final class TemplateSearchPopover: NSObject, NSSearchFieldDelegate {
    private static let width: CGFloat = 300
    private static let listHeight: CGFloat = 8 * TemplateRowView.height

    private let choices: [TemplateChoice]
    private let onChoose: (UUID) -> Void
    private let popover = NSPopover()
    private let field = NSSearchField()
    private let list = TemplateFlippedView()
    private let scroll = NSScrollView()
    private var found: [TemplateChoice] = []
    private var rows: [TemplateRowView] = []
    private var selected = 0 { didSet { rows.enumerated().forEach { $1.isSelected = $0 == selected } } }

    init(choices: [TemplateChoice], onChoose: @escaping (UUID) -> Void) {
        self.choices = choices
        self.onChoose = onChoose
        super.init()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 44 + Self.listHeight))
        field.frame = NSRect(x: 8, y: Self.listHeight + 8, width: Self.width - 16, height: 28)
        field.placeholderString = "Поиск шаблонов…"
        field.delegate = self
        field.setAccessibilityIdentifier("template-search")
        scroll.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.listHeight)
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        content.addSubview(scroll)
        content.addSubview(field)
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
        reload()
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(field)
    }

    func close() { popover.close() }

    private func reload() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        found = query.isEmpty ? choices : choices.filter { $0.title.localizedCaseInsensitiveContains(query) }
        rows.forEach { $0.removeFromSuperview() }
        rows = found.enumerated().map { index, choice in
            let row = TemplateRowView(title: choice.title.isEmpty ? "Без названия" : choice.title, icon: choice.icon)
            row.frame = NSRect(x: 4, y: CGFloat(index) * TemplateRowView.height, width: Self.width - 8, height: TemplateRowView.height)
            row.onClick = { [weak self] in self?.choose(choice) }
            row.setAccessibilityIdentifier("template-search-row-\(index)")
            list.addSubview(row)
            return row
        }
        list.frame = NSRect(x: 0, y: 0, width: Self.width, height: max(Self.listHeight, CGFloat(rows.count) * TemplateRowView.height))
        selected = 0
    }

    private func choose(_ choice: TemplateChoice) {
        popover.close()
        onChoose(choice.id)
    }

    func controlTextDidChange(_ notification: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): selected = min(selected + 1, max(found.count - 1, 0))
        case #selector(NSResponder.moveUp(_:)): selected = max(selected - 1, 0)
        case #selector(NSResponder.insertNewline(_:)): if found.indices.contains(selected) { choose(found[selected]) }
        default: return false
        }
        return true
    }
}

final class TemplateFlippedView: NSView {
    override var isFlipped: Bool { true }
}
