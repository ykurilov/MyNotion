import AppKit
import NotesCore
import VisualStyle

/// Блок-ссылка на страницу, у которого правой кнопкой открыли меню страницы.
public struct PageLinkMenuRequest: Sendable {
    /// Страница по ссылке — на неё действуют пункты страницы.
    public let pageId: UUID
    public let blockId: UUID
    /// Строка блока в координатах экрана: у неё встают окна пунктов («Сменить иконку», «Переименовать»).
    public let anchor: NSRect

    public init(pageId: UUID, blockId: UUID, anchor: NSRect) {
        self.pageId = pageId
        self.blockId = blockId
        self.anchor = anchor
    }
}

/// Меню блока-ссылки на страницу по правой кнопке, как у Notion 7.39: сверху — «Преобразовать в ›» и «Цвет ›» меню блока,
/// под чертой — пункты страницы от хозяина окна (`PageTextView.pageLinkMenuEntries`). Карточка — как меню строки панели;
/// подменю — дочерние окна карточки: щелчок в них карточку не закрывает.
@MainActor
final class PageLinkMenuPresenter {
    weak var textView: PageTextView?
    private let card = PopupCard()
    /// Открытое меню; `nil` — закрыто.
    private(set) var menu: ActionMenuView?
    private var blockId: UUID?
    private var kindList: PopupMenuWindow?

    init() {
        card.onClose = { [weak self] in self?.didClose() }
    }

    var isShown: Bool { card.isShown }

    /// Показать `menu` для блока `blockId` от точки `point` вида `view`.
    func show(_ menu: ActionMenuView, forBlock blockId: UUID, from point: NSPoint, in view: NSView) {
        close()
        self.menu = menu
        self.blockId = blockId
        menu.onChoose = { [weak self] in self?.card.close() }
        card.show(menu, size: menu.fittingSize, from: view.convert(point, to: nil), in: view)
    }

    func close() {
        card.close()
        didClose()
    }

    private func didClose() {
        closeSubmenus()
        menu = nil
        blockId = nil
    }

    private func closeSubmenus() {
        kindList?.hide()
        if let blockId, textView?.colorMenu.target == .block(blockId) { textView?.colorMenu.close() }
    }

    /// Строки меню блока: те же «Преобразовать в» и «Цвет», что в меню «⋮⋮».
    func blockEntries(forBlock blockId: UUID) -> [ActionMenuEntry] {
        [PopupMenuItem.turnInto, PopupMenuItem.color].map { item in
            .action(ActionMenuAction(title: item.title, icon: Self.symbol(of: item), opensSubmenu: true,
                                     identifier: "page-link-menu-\(item.identifier)") { [weak self] row in
                self?.openSubmenu(item.action, forBlock: blockId, besides: row)
            })
        }
    }

    private static func symbol(of item: PopupMenuItem) -> String? {
        if case .symbol(let name) = item.icon { name } else { nil }
    }

    private func openSubmenu(_ action: PopupMenuItem.Action, forBlock blockId: UUID, besides row: NSView) {
        guard let textView, let card = row.window, let menu else { return }
        closeSubmenus()
        let rowOnScreen = card.convertToScreen(row.convert(row.bounds, to: nil))
        let menuOnScreen = card.convertToScreen(menu.convert(menu.bounds, to: nil))
        switch action {
        case .turnInto:
            let list = kindList ?? PopupMenuWindow(style: .kindPicker)
            kindList = list
            list.menuView.setItems(PopupMenuItem.blockKinds)
            let current = textView.document.blocks.first { $0.id == blockId }.map(\.kind)
            list.menuView.checkedItem = PopupMenuItem.blockKinds.first { $0.action == current.map(PopupMenuItem.Action.setKind) }
            if let checked = list.menuView.checkedItem { list.menuView.select(checked) }
            list.menuView.onChoose = { [weak self, weak textView] item in
                self?.close()
                textView?.applyPopupItem(item, session: .block(blockId: blockId))
            }
            list.show(besideRow: rowOnScreen, of: menuOnScreen, parent: card)
        case .color:
            textView.openColorMenu(forBlock: blockId, besideRow: rowOnScreen, of: menuOnScreen, parent: card)
        default:
            break
        }
    }
}

extension PageTextView {
    /// Правая кнопка по блоку-ссылке на страницу — меню страницы вместо системного меню текста; по остальному — как было.
    override public func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let (index, pageId, row) = linkedPageRow(at: point) else { return super.menu(for: event) }
        let blockId = document.blocks[index].id
        let anchor = window.map { $0.convertToScreen(convert(row, to: nil)) } ?? .zero
        let menu = pageLinkMenuView(forBlock: blockId, pageId: pageId, anchor: anchor)
        // Блок подсвечен, как при меню «⋮⋮»: видно, к чему меню.
        window?.makeFirstResponder(self)
        selectBlocks(index..<index + 1)
        pageLinkMenu.show(menu, forBlock: blockId, from: point, in: self)
        return nil
    }

    /// Меню блока-ссылки: строки меню блока, черта, пункты страницы от хозяина окна.
    func pageLinkMenuView(forBlock blockId: UUID, pageId: UUID, anchor: NSRect) -> ActionMenuView {
        var entries = pageLinkMenu.blockEntries(forBlock: blockId)
        let pageEntries = pageLinkMenuEntries?(PageLinkMenuRequest(pageId: pageId, blockId: blockId, anchor: anchor)) ?? []
        if !pageEntries.isEmpty { entries += [.separator] + pageEntries }
        return ActionMenuView(entries: entries, width: Metrics.PageMenu.width)
    }
}
