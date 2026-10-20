import AppKit
import NotesCore
import SwiftUI
import VisualStyle

/// Меню «•••» страницы из описателей (contracts/pages-ui.md) в карточке всплывающих меню 002 (`PopupCard`, `PopupSurface`):
/// поле «Найти действие…» сверху сужает меню до пунктов с запросом в названии, подвал — серым.
@MainActor
public final class PageMenuPresenter {
    let view: PageMenuView
    private let card = PopupCard()

    public init(items: [PageMenuItem], context: PageMenuContext) {
        view = PageMenuView(rows: PageMenuLayout.rows(items, context: context), context: context)
        view.onChoose = { [weak self] in self?.card.close() }
        card.onClose = { [weak view] in view?.submenu.close() }
    }

    public var isShown: Bool { card.isShown }

    /// Показать карточку под видом `anchor`, правым краем по нему.
    public func show(below anchor: NSView) {
        card.show(view, size: view.fittingSize, besides: anchor, gap: Metrics.PopupMenu.anchorSpacing, preferringRight: false)
        view.focusSearch()
    }

    public func close() { card.close() }
}

/// Строки меню «•••»: поле поиска, пункты, линии, подвал.
@MainActor
final class PageMenuView: NSView, NSSearchFieldDelegate {
    private let context: PageMenuContext
    private var searchField: NSSearchField?
    private var entries: [(row: NSView, title: String?)] = []
    var onChoose: (() -> Void)?
    /// Подменю с переключателями («Вид страницы ›»).
    let submenu = PageMenuSubmenu()

    init(rows: [PageMenuRow], context: PageMenuContext) {
        self.context = context
        super.init(frame: .zero)
        for row in rows {
            switch row {
            case .separator:
                entries.append((PageMenuSeparatorView(), nil))
            case .item(let item):
                entries += makeRows(item)
            }
        }
        entries.forEach { addSubview($0.row) }
        frame.size = fittingSize
        layoutRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private func makeRows(_ item: PageMenuItem) -> [(NSView, String?)] {
        let title = item.title(context)
        let context = context
        switch item.kind {
        case .search:
            let field = NSSearchField()
            field.placeholderString = title
            field.delegate = self
            field.focusRingType = .none
            field.setAccessibilityIdentifier("page-menu-search")
            searchField = field
            return [(field, nil)]
        case .footer:
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: Typography.popupMenuShortcut.fontSize)
            label.textColor = Palette.textSecondary
            label.setAccessibilityIdentifier("page-menu-footer")
            return [(label, nil)]
        case .action(let perform, let shortcut):
            let row = PageMenuRowView(title: title, hint: shortcut) { [weak self] in
                perform(context)
                self?.onChoose?()
            }
            return [(row, title)]
        case .toggles(let toggles):
            // Как у Notion: строка «Вид страницы ›» открывает сбоку подменю с переключателями; переключение меню не закрывает.
            let row = PageMenuRowView(title: title, hint: "›") { [weak self] in
                guard let self else { return }
                self.submenu.show(toggles, context: context, besides: self.entries.first { $0.title == title }?.row)
            }
            row.onHover = { [weak row] in row?.press() }
            row.setAccessibilityIdentifier("page-menu-\(item.slot)")
            return [(row, title)]
        }
    }

    override var fittingSize: NSSize {
        let height = entries.filter { !$0.row.isHidden }.reduce(2 * Metrics.PopupMenu.verticalPadding) { $0 + rowHeight($1.row) }
        return NSSize(width: Metrics.PageMenu.width, height: height)
    }

    private func rowHeight(_ row: NSView) -> CGFloat {
        switch row {
        case is PageMenuSeparatorView: Metrics.PopupMenu.groupSeparatorHeight
        case is NSSearchField: Metrics.PopupMenu.rowHeight
        case is PageMenuRowView: Metrics.PopupMenu.compactRowHeight
        default: Metrics.PopupMenu.compactRowHeight
        }
    }

    private func layoutRows() {
        var y = Metrics.PopupMenu.verticalPadding
        let inset = Metrics.PopupMenu.rowInset
        for (row, _) in entries where !row.isHidden {
            let height = rowHeight(row)
            switch row {
            case is NSSearchField:
                row.frame = NSRect(x: Metrics.PageMenu.searchInset, y: y + 4, width: bounds.width - 2 * Metrics.PageMenu.searchInset, height: height - 8)
            case is NSTextField:
                row.frame = NSRect(x: inset + Metrics.PopupMenu.rowHorizontalPadding, y: y + (height - 16) / 2, width: bounds.width - 2 * inset, height: 16)
            default:
                row.frame = NSRect(x: inset, y: y, width: bounds.width - 2 * inset, height: height)
            }
            y += height
        }
    }

    override func layout() {
        super.layout()
        layoutRows()
    }

    func focusSearch() {
        if let searchField { window?.makeFirstResponder(searchField) }
    }

    func controlTextDidChange(_ notification: Notification) {
        filter(searchField?.stringValue ?? "")
    }

    /// Оставить пункты, в названии которых есть запрос; при запросе линии и подвал прячутся.
    func filter(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespaces)
        submenu.close()
        for (row, title) in entries where !(row is NSSearchField) {
            if let title {
                row.isHidden = !query.isEmpty && title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil
            } else {
                row.isHidden = !query.isEmpty
            }
        }
        needsLayout = true
    }

    /// Названия видимых пунктов — для проверок.
    var visibleTitles: [String] { entries.filter { !$0.row.isHidden }.compactMap(\.title) }
}

/// Пункт меню: название, серая подсказка справа, подложка под мышью.
@MainActor
final class PageMenuRowView: NSView {
    let title: String
    private let action: () -> Void
    private let titleLabel: NSTextField
    private let hintLabel: NSTextField
    private var isHovered = false { didSet { needsDisplay = true } }
    /// Мышь пришла на пункт (подменю открывается наведением).
    var onHover: (() -> Void)?

    init(title: String, hint: String?, action: @escaping () -> Void) {
        self.title = title
        self.action = action
        titleLabel = NSTextField(labelWithString: title)
        hintLabel = NSTextField(labelWithString: hint ?? "")
        super.init(frame: .zero)
        titleLabel.font = Typography.popupMenuTitle.font
        titleLabel.textColor = Palette.textPrimary
        hintLabel.font = .systemFont(ofSize: Typography.popupMenuShortcut.fontSize)
        hintLabel.textColor = Palette.textSecondary
        addSubview(titleLabel)
        addSubview(hintLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let padding = Metrics.PopupMenu.rowHorizontalPadding
        let hint = hintLabel.intrinsicContentSize
        hintLabel.frame = NSRect(x: bounds.width - padding - hint.width, y: (bounds.height - hint.height) / 2, width: hint.width, height: hint.height)
        let titleSize = titleLabel.intrinsicContentSize
        titleLabel.frame = NSRect(x: padding, y: (bounds.height - titleSize.height) / 2, width: hintLabel.frame.minX - 2 * padding, height: titleSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        Palette.hoverBackground.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: Metrics.PopupMenu.rowHighlightInset, dy: 0), xRadius: Metrics.PopupMenu.rowCornerRadius,
                     yRadius: Metrics.PopupMenu.rowCornerRadius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?()
    }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    func press() { action() }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}

/// Линия между группами меню.
final class PageMenuSeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Palette.border.setFill()
        NSRect(x: Metrics.PopupMenu.rowHorizontalPadding, y: bounds.midY, width: bounds.width - 2 * Metrics.PopupMenu.rowHorizontalPadding, height: 1).fill()
    }
}

/// Кнопка «•••» справа в верхней полосе страницы: меню из описателей.
struct PageMenuButton: NSViewRepresentable {
    let items: [PageMenuItem]
    let context: @MainActor () -> PageMenuContext

    /// Одна картинка на все страницы; кнопка без `sizeToFit` — размер задаёт верхняя полоса, а замер символа
    /// стоил каждому открытию страницы (профиль переключения вкладок, 003).
    private static let image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Настройки и действия страницы")!

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: .zero)
        button.image = Self.image
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = #selector(Coordinator.open(_:))
        button.isBordered = false
        button.toolTip = "Настройки и действия страницы"
        button.contentTintColor = Palette.textSecondary
        button.setAccessibilityIdentifier("page-menu")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PageMenuButton
        private var presenter: PageMenuPresenter?

        init(parent: PageMenuButton) { self.parent = parent }

        @objc func open(_ sender: NSButton) {
            let presenter = PageMenuPresenter(items: parent.items, context: parent.context())
            self.presenter = presenter
            presenter.show(below: sender)
        }
    }
}
