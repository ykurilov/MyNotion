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

/// Строки меню «•••» — меню действий (`ActionMenuView`) из описателей: значки по местам, подменю «Вид страницы ›».
@MainActor
final class PageMenuView: NSView {
    let actions: ActionMenuView
    var onChoose: (() -> Void)? {
        get { actions.onChoose }
        set { actions.onChoose = newValue }
    }
    /// Подменю с переключателями («Вид страницы ›»).
    let submenu = PageMenuSubmenu()

    init(rows: [PageMenuRow], context: PageMenuContext) {
        let submenu = self.submenu
        let entries: [ActionMenuEntry] = rows.map { row in
            switch row {
            case .separator: return .separator
            case .item(let item): return Self.entry(item, context: context, submenu: submenu)
            }
        }
        actions = ActionMenuView(entries: entries, width: Metrics.PageMenu.width)
        super.init(frame: NSRect(origin: .zero, size: actions.fittingSize))
        actions.onFilter = { [weak submenu] in submenu?.close() }
        actions.autoresizingMask = [.width, .height]
        actions.frame = bounds
        addSubview(actions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { actions.fittingSize }

    private static func entry(_ item: PageMenuItem, context: PageMenuContext, submenu: PageMenuSubmenu) -> ActionMenuEntry {
        let title = item.title(context)
        let identifier = "page-menu-\(item.slot)"
        switch item.kind {
        case .search:
            return .search(placeholder: title, identifier: "page-menu-search")
        case .footer:
            return .footer(title, identifier: "page-menu-footer")
        case .action(let perform, let shortcut):
            return .action(ActionMenuAction(title: title, icon: item.slot.icon, hint: shortcut, identifier: identifier) { _ in perform(context) })
        case .toggles(let toggles):
            // Как у Notion: строка «Вид страницы ›» открывает сбоку подменю с переключателями; переключение меню не закрывает.
            return .action(ActionMenuAction(title: title, icon: item.slot.icon, opensSubmenu: true, identifier: identifier) { row in
                submenu.show(toggles, context: context, besides: row)
            })
        }
    }

    func focusSearch() { actions.focusSearch() }

    /// Оставить пункты, в названии которых есть запрос; при запросе линии и подвал прячутся.
    func filter(_ query: String) { actions.filter(query) }

    /// Названия видимых пунктов — для проверок.
    var visibleTitles: [String] { actions.visibleTitles }
}

extension PageMenuSlot {
    /// Значок пункта (SF Symbols) — близкий к значку того же пункта у Notion 7.39.
    var icon: String? {
        switch self {
        case .findAction, .footer: nil
        case .duplicate: "square.on.square"
        case .moveTo: "arrow.turn.up.right"
        case .versionHistory: "clock.arrow.circlepath"
        case .appearance: "textformat"
        case .template: "doc.on.doc"
        case .trash: "trash"
        }
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
