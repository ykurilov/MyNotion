import AppKit
import VisualStyle

/// «Ещё шаблоны…»: поиск по названиям всех шаблонов в карточке всплывающих меню под строкой «Ещё шаблоны…»
/// (строки шаблонов над ней не закрывает), высотой по найденному — не больше 8 строк. ↑↓ меняют строку, Enter выбирает, Esc закрывает.
@MainActor
final class TemplateSearchPopover: NSObject, NSSearchFieldDelegate {
    static let width: CGFloat = 300
    static let maxVisibleRows = 8
    /// Поле 28 в 8 от верха, под ним 8 до списка, снизу 4.
    static let fieldTop: CGFloat = 8
    static let fieldHeight: CGFloat = 28
    static let listTop: CGFloat = fieldTop + fieldHeight + 8
    static let bottomPadding: CGFloat = 4

    private let choices: [TemplateChoice]
    private let onChoose: (UUID) -> Void
    private let card = PopupCard()
    let content = TemplateFlippedView()
    private let field = NSSearchField()
    private let list = TemplateFlippedView()
    private let scroll = NSScrollView()
    private var found: [TemplateChoice] = []
    private(set) var rows: [TemplateRowView] = []
    private var selected = 0 { didSet { rows.enumerated().forEach { $1.isSelected = $0 == selected } } }

    init(choices: [TemplateChoice], onChoose: @escaping (UUID) -> Void) {
        self.choices = choices
        self.onChoose = onChoose
        super.init()
        field.placeholderString = "Поиск шаблонов…"
        field.delegate = self
        field.setAccessibilityIdentifier("template-search")
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        content.addSubview(scroll)
        content.addSubview(field)
        reload()
    }

    /// Высота карточки при `count` найденных: по строкам, не больше восьми.
    static func height(forRows count: Int) -> CGFloat {
        listTop + CGFloat(min(max(count, 1), maxVisibleRows)) * TemplateRowView.height + bottomPadding
    }

    /// Показать под строкой `anchor` («Ещё шаблоны…») левым краем по ней.
    func show(below anchor: NSView) {
        let size = NSSize(width: Self.width, height: Self.height(forRows: found.count))
        layout(size)
        let point = NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.maxY + 4 : anchor.bounds.minY - 4)
        card.show(content, size: size, from: anchor.convert(point, to: nil), in: anchor)
        content.window?.makeFirstResponder(field)
    }

    var isShown: Bool { card.isShown }

    func close() { card.close() }

    private func layout(_ size: NSSize) {
        content.frame = NSRect(origin: .zero, size: size)
        field.frame = NSRect(x: 8, y: Self.fieldTop, width: size.width - 16, height: Self.fieldHeight)
        scroll.frame = NSRect(x: 0, y: Self.listTop, width: size.width, height: size.height - Self.listTop - Self.bottomPadding)
    }

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
        list.frame = NSRect(x: 0, y: 0, width: Self.width, height: CGFloat(rows.count) * TemplateRowView.height)
        selected = 0
    }

    private func choose(_ choice: TemplateChoice) {
        card.close()
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
