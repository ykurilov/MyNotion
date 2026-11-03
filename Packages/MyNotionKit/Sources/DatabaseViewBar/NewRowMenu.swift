import AppKit
import DatabaseGrid
import Databases
import VisualStyle

/// «Создать ▾» (spec US6, `notion-new-dropdown-templates.png`): «Шаблоны для «X»», шаблоны базы с меткой «По умолчанию»
/// и «•••», «Пустая страница», «+ Новый шаблон». Без шаблонов — подсказка и «+ Новый шаблон» (`notion-new-dropdown-templates-empty.png`).
@MainActor
public final class NewRowMenuView: NSView {
    public enum Command: Equatable {
        case create(RowTemplateChoice)
        case newTemplate
        /// «•••» у шаблона; `nil` — у «Пустой страницы».
        case more(UUID?)
    }

    public static let width: CGFloat = 240
    private static let hintText = "Создайте шаблон страницы для этой базы."
    private static let hintFont = NSFont.systemFont(ofSize: Typography.popupMenuShortcut.fontSize)
    private static let headerHeight: CGFloat = 32
    private static let hintHeight: CGFloat = 24

    /// Выбор: `anchor` — строка, у которой нажали «•••» (под ней встаёт меню шаблона).
    public var onCommand: ((Command, NSView) -> Void)?
    private let header: NSAttributedString
    private let showsHint: Bool
    private var rows: [NSView] = []

    public init(databaseTitle: String, list: RowTemplateList) {
        let name = databaseTitle.isEmpty ? "Без названия" : databaseTitle
        header = NSAttributedString(string: "Шаблоны для «\(name)»", attributes: [
            .font: NSFont.systemFont(ofSize: Typography.popupMenuSectionHeader.fontSize, weight: .medium), .foregroundColor: Palette.textSecondary,
        ])
        showsHint = list.templates.isEmpty
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
        setAccessibilityIdentifier("database-new-row-menu")
        if !list.templates.isEmpty {
            for template in list.templates {
                rows.append(NewRowTemplateRow(title: template.title.isEmpty ? "Без названия" : template.title, icon: .page(template.icon),
                                              isDefault: list.defaultTemplateId == template.id, identifier: "row-template-\(template.id)",
                                              choose: { [weak self] row in self?.onCommand?(.create(.template(template.id)), row) },
                                              more: { [weak self] row in self?.onCommand?(.more(template.id), row) }))
            }
            rows.append(NewRowTemplateRow(title: "Пустая страница", icon: .page(nil), isDefault: list.defaultTemplateId == nil, identifier: "row-template-empty",
                                          choose: { [weak self] row in self?.onCommand?(.create(.empty), row) },
                                          more: { [weak self] row in self?.onCommand?(.more(nil), row) }))
            rows.append(NewRowSeparator())
        }
        rows.append(NewRowTemplateRow(title: "Новый шаблон", icon: .plus, isDefault: false, identifier: "row-template-new",
                                      choose: { [weak self] row in self?.onCommand?(.newTemplate, row) }, more: nil))
        rows.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public override var isFlipped: Bool { true }

    /// Подсказка пустого меню — в одну строку: карточка шире на её длину.
    private var width: CGFloat {
        guard showsHint else { return Self.width }
        let hint = (Self.hintText as NSString).size(withAttributes: [.font: Self.hintFont]).width
        return max(Self.width, ceil(hint) + 2 * Metrics.PopupMenu.rowHorizontalPadding)
    }

    private var topOfRows: CGFloat { Self.headerHeight + (showsHint ? Self.hintHeight : 0) }

    public override var fittingSize: NSSize {
        NSSize(width: width, height: topOfRows + rows.map(height(of:)).reduce(0, +) + Metrics.PopupMenu.rowHorizontalPadding / 2)
    }

    private func height(of row: NSView) -> CGFloat { row is NewRowTemplateRow ? Metrics.PopupMenu.compactRowHeight : Metrics.PopupMenu.groupSeparatorHeight }

    public override func layout() {
        super.layout()
        var y = topOfRows
        for row in rows {
            let height = height(of: row)
            row.frame = NSRect(x: 4, y: y, width: bounds.width - 8, height: height)
            y += height
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let padding = Metrics.PopupMenu.rowHorizontalPadding
        header.draw(at: NSPoint(x: padding, y: (Self.headerHeight - header.size().height) / 2 + 2))
        guard showsHint else { return }
        NSAttributedString(string: Self.hintText, attributes: [
            .font: Self.hintFont, .foregroundColor: Palette.textSecondary,
        ]).draw(at: NSPoint(x: padding, y: Self.headerHeight))
    }
}

/// Строка меню «Создать ▾»: значок (эмодзи шаблона или «документ»), название, серая «По умолчанию», «•••» при наведении.
@MainActor
final class NewRowTemplateRow: NSView {
    enum Icon: Equatable {
        /// Эмодзи страницы-шаблона; `nil` — значок документа.
        case page(String?)
        case plus
    }

    private let title: String
    private let icon: Icon
    private let isDefault: Bool
    private let choose: (NSView) -> Void
    private let moreButton: NewRowMoreButton?
    private var isHovered = false { didSet { needsDisplay = true } }

    init(title: String, icon: Icon, isDefault: Bool, identifier: String, choose: @escaping (NSView) -> Void, more: ((NSView) -> Void)?) {
        self.title = title
        self.icon = icon
        self.isDefault = isDefault
        self.choose = choose
        moreButton = more.map { NewRowMoreButton(identifier: "\(identifier)-more", press: $0) }
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(isDefault ? "\(title), по умолчанию" : title)
        setAccessibilityIdentifier(identifier)
        if let moreButton {
            moreButton.row = self
            addSubview(moreButton)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var itemRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: Metrics.ActionMenu.highlightHeight) }

    override func layout() {
        super.layout()
        moreButton?.frame = NSRect(x: bounds.maxX - 28, y: (itemRect.height - 20) / 2, width: 20, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let padding = Metrics.PopupMenu.rowHorizontalPadding
        if isHovered {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: itemRect, xRadius: Metrics.PopupMenu.rowCornerRadius, yRadius: Metrics.PopupMenu.rowCornerRadius).fill()
        }
        let side = Metrics.PopupMenu.iconSize
        let iconRect = NSRect(x: padding, y: ((itemRect.height - side) / 2).rounded(), width: side, height: side)
        switch icon {
        case .plus: ActionMenuIcon.draw("plus", color: Palette.textSecondary, in: iconRect)
        case .page(nil): DocumentGlyph.image(size: iconRect.width, color: Palette.sidebarIcon).draw(in: iconRect.insetBy(dx: 2, dy: 2))
        case .page(let emoji?):
            let string = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: 14)])
            let size = string.size()
            string.draw(at: NSPoint(x: iconRect.midX - size.width / 2, y: iconRect.midY - size.height / 2))
        }
        var titleEnd = bounds.maxX - padding - (moreButton == nil ? 0 : 24)
        if isDefault {
            let label = NSAttributedString(string: "По умолчанию", attributes: [
                .font: NSFont.systemFont(ofSize: Typography.popupMenuShortcut.fontSize), .foregroundColor: Palette.textSecondary,
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: titleEnd - size.width, y: (itemRect.height - size.height) / 2))
            titleEnd -= size.width + padding
        }
        let style = Typography.popupMenuTitle
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let titleX = padding + side + Metrics.PopupMenu.iconToTitleSpacing
        NSAttributedString(string: title, attributes: [
            .font: style.font, .foregroundColor: icon == .plus ? Palette.textSecondary : Palette.textPrimary, .paragraphStyle: paragraph,
        ]).draw(in: NSRect(x: titleX, y: (itemRect.height - style.lineHeight) / 2, width: max(0, titleEnd - titleX), height: style.lineHeight))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { choose(self) }
    }

    override func accessibilityPerformPress() -> Bool {
        choose(self)
        return true
    }
}

/// Черта между шаблонами и «+ Новый шаблон».
private final class NewRowSeparator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Palette.border.setFill()
        NSRect(x: Metrics.PopupMenu.rowHorizontalPadding - 4, y: bounds.midY, width: bounds.width - 2 * (Metrics.PopupMenu.rowHorizontalPadding - 4), height: 1).fill()
    }
}

/// «•••» строки шаблона: меню «Сделать по умолчанию / Изменить / Дублировать / Удалить».
@MainActor
private final class NewRowMoreButton: NSView {
    weak var row: NSView?
    private let press: (NSView) -> Void

    init(identifier: String, press: @escaping (NSView) -> Void) {
        self.press = press
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Ещё")
        setAccessibilityIdentifier(identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func draw(_ dirtyRect: NSRect) {
        ActionMenuIcon.draw("ellipsis", color: Palette.textSecondary, in: bounds.insetBy(dx: 2, dy: 2))
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press(row ?? self) }
    }

    override func accessibilityPerformPress() -> Bool {
        press(row ?? self)
        return true
    }
}

/// Меню «Создать ▾» таблицы: строка по шаблону открывается способом вида; новый шаблон и «Изменить» — по центру, как у Notion.
extension DatabaseTableView {
    func showNewRowMenu(from anchor: NSView) {
        guard let list = try? RowTemplates.list(of: controller.databaseId, in: controller.store), let content = window?.contentView else { return }
        let menu = NewRowMenuView(databaseTitle: controller.title, list: list)
        menu.onCommand = { [weak self] command, row in self?.perform(command, from: row, list: list) }
        let size = menu.fittingSize
        let rect = anchor.convert(anchor.bounds, to: nil)
        // Правым краем по «Создать ▾» (вся кнопка — родитель «▾»), как у Notion.
        let right = (anchor.superview ?? anchor).convert((anchor.superview ?? anchor).bounds, to: nil).maxX
        newRowMenuCard.show(menu, size: size, from: NSPoint(x: right - size.width, y: rect.minY - 4), in: content)
    }

    private func perform(_ command: NewRowMenuView.Command, from row: NSView, list: RowTemplateList) {
        switch command {
        case .create(let template):
            newRowMenuCard.close()
            guard let index = controller.addRow(at: .top, template: template) else { return }
            controller.openRow(index)
        case .newTemplate:
            newRowMenuCard.close()
            editRowTemplate { try $0.addRowTemplate(to: self.controller.databaseId) }
        case .more(let templateId):
            showTemplateMenu(templateId, isDefault: list.defaultTemplateId == templateId, below: row)
        }
    }

    /// «•••» шаблона (`notion-template-item-menu.png`); у «Пустой страницы» — только «Сделать по умолчанию».
    private func showTemplateMenu(_ templateId: UUID?, isDefault: Bool, below row: NSView) {
        let databaseId = controller.databaseId
        var entries: [ActionMenuEntry] = []
        if !isDefault {
            entries.append(.action(ActionMenuAction(title: "Сделать по умолчанию", icon: "checkmark.circle", identifier: "row-template-set-default") { [weak self] _ in
                self?.closeNewRowMenu()
                self?.attemptTemplateEdit { try $0.setDefaultRowTemplate(templateId, of: databaseId) }
            }))
        }
        if let templateId {
            entries.append(.action(ActionMenuAction(title: "Изменить", icon: "pencil", identifier: "row-template-edit") { [weak self] _ in
                self?.closeNewRowMenu()
                self?.controller.onOpenRow?(templateId, .centerPeek, false)
            }))
            entries.append(.action(ActionMenuAction(title: "Дублировать", icon: "plus.square.on.square", identifier: "row-template-duplicate") { [weak self] _ in
                self?.closeNewRowMenu()
                self?.editRowTemplate { try $0.duplicateRowTemplate(templateId) }
            }))
            entries.append(.action(ActionMenuAction(title: "Удалить", icon: "trash", identifier: "row-template-delete") { [weak self] _ in
                self?.closeNewRowMenu()
                self?.attemptTemplateEdit { try $0.trashRowTemplate(templateId) }
            }))
        }
        guard !entries.isEmpty else { return }
        let menu = ActionMenuView(entries: entries, width: Metrics.PageMenu.width)
        menu.onChoose = { [weak self] in self?.templateMenuCard.close() }
        templateMenuCard.show(menu, size: menu.fittingSize, besides: row, gap: 4)
    }

    private func closeNewRowMenu() {
        templateMenuCard.close()
        newRowMenuCard.close()
    }

    /// Новый шаблон или копия: открывается по центру с янтарной полосой «Вы правите шаблон».
    private func editRowTemplate(_ body: (DatabaseOperations) throws -> UUID) {
        var created: UUID?
        attemptTemplateEdit { created = try body($0) }
        if let created { controller.onOpenRow?(created, .centerPeek, false) }
    }

    private func attemptTemplateEdit(_ body: (DatabaseOperations) throws -> Void) {
        do { try body(controller.operations) } catch { NSLog("MyNotion: правка шаблона строки не удалась: \(error.localizedDescription)") }
    }
}
