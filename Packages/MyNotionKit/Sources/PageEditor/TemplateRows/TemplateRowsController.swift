import AppKit
import VisualStyle

/// Строки шаблонов на пустой странице (contracts/pages-ui.md, «Шаблоны на пустой странице»): серый заголовок
/// «Шаблоны», до пяти строк и «Ещё шаблоны…». Виды появляются, только когда страница пуста и шаблоны есть.
@MainActor
final class TemplateRowsController {
    static let visibleLimit = 5
    private static let moreTitle = "Ещё шаблоны…"

    private weak var textView: PageTextView?
    let container = TemplateFlippedView()
    let heading = NSTextField(labelWithString: "Шаблоны")
    private(set) var rows: [TemplateRowView] = []
    private var shown: [TemplateChoice] = []
    private var hasMore = false
    private(set) var selectedIndex: Int? {
        didSet { for (index, row) in rows.enumerated() { row.isSelected = index == selectedIndex } }
    }
    private(set) var searchPopover: TemplateSearchPopover?

    init(textView: PageTextView) {
        self.textView = textView
        container.setAccessibilityIdentifier("template-rows")
        heading.font = .systemFont(ofSize: 12, weight: .medium)
        heading.textColor = Palette.textSecondary
        heading.setAccessibilityIdentifier("template-rows-heading")
        container.addSubview(heading)
        textView.addSubview(container)
    }

    /// Строк сейчас: шаблоны и «Ещё шаблоны…».
    var rowCount: Int { rows.count }

    var isVisible: Bool { !container.isHidden && container.superview != nil }

    func hide() {
        guard !container.isHidden else { return }
        container.isHidden = true
        selectedIndex = nil
        searchPopover?.close()
    }

    /// Показать строки под первой строкой страницы: `left` — где начинается её текст, `top` — нижний край этой строки.
    func show(_ choices: [TemplateChoice], left: CGFloat, top: CGFloat, width: CGFloat) {
        if choices != shown || rows.isEmpty { rebuild(choices) }
        container.isHidden = false
        let headingHeight: CGFloat = 20
        let gap: CGFloat = 14
        let height = headingHeight + CGFloat(rows.count) * TemplateRowView.height + 4
        container.frame = NSRect(x: left, y: top + gap, width: width, height: height)
        heading.frame = NSRect(x: 0, y: 0, width: width - 4, height: headingHeight)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: headingHeight + CGFloat(index) * TemplateRowView.height, width: width, height: TemplateRowView.height)
        }
    }

    private func rebuild(_ choices: [TemplateChoice]) {
        rows.forEach { $0.removeFromSuperview() }
        shown = choices
        selectedIndex = nil
        rows = choices.prefix(Self.visibleLimit).enumerated().map { index, choice in
            let row = TemplateRowView(title: choice.title.isEmpty ? "Без названия" : choice.title, icon: choice.icon)
            row.onClick = { [weak self] in self?.textView?.chooseTemplate(choice.id) }
            row.setAccessibilityIdentifier("template-row-\(index)")
            return row
        }
        hasMore = choices.count > Self.visibleLimit
        if hasMore {
            let more = TemplateRowView(title: Self.moreTitle, icon: nil, symbol: "ellipsis")
            more.onClick = { [weak self] in self?.showSearch() }
            more.setAccessibilityIdentifier("template-rows-more")
            rows.append(more)
        }
        rows.forEach { container.addSubview($0) }
    }

    // MARK: Клавиши

    /// ↓ — к первой строке и дальше, ↑ — назад и обратно в текст; Enter — выбрать. `true` — клавишу взяли.
    func handle(_ selector: Selector) -> Bool {
        guard isVisible else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            selectedIndex = min((selectedIndex ?? -1) + 1, rows.count - 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard let index = selectedIndex else { return false }
            selectedIndex = index == 0 ? nil : index - 1
            return true
        case #selector(NSResponder.insertNewline(_:)):
            guard let index = selectedIndex else { return false }
            activate(index)
            return true
        default:
            return false
        }
    }

    private func activate(_ index: Int) {
        if hasMore, index == rows.count - 1 {
            showSearch()
        } else if shown.indices.contains(index) {
            textView?.chooseTemplate(shown[index].id)
        }
    }

    // MARK: «Ещё шаблоны…»

    private func showSearch() {
        guard let textView, let anchor = rows.last else { return }
        let popover = TemplateSearchPopover(choices: shown) { [weak textView] id in textView?.chooseTemplate(id) }
        searchPopover = popover
        popover.show(below: anchor)
    }
}
