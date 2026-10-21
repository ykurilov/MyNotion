import AppKit
import Databases
import NotesCore
import VisualStyle

/// Окно «Свойства» базы (contracts/database-ui.md): «Свойства ×», свойства по порядку с ручками «⠿» (перетаскивание —
/// `PropertiesList.move`), щелчок по свойству — «Изменить свойство» на месте окна, «+ Новое свойство» (имя и тип),
/// сверх Notion — «Удалённые свойства» с «Вернуть» и «Удалить навсегда».
@MainActor
final class PropertiesWindowView: NSView {
    private enum Screen: Equatable { case list, edit(UUID), new }

    private let commands: PropertyMenuCommands
    private var screen = Screen.list
    private let scroll = NSScrollView()
    private let stack = PropertyPopupStack()
    private var list = PropertiesList(active: [], deleted: [])
    private var propertyRows: [(id: UUID, view: PropertyRowWithHandle)] = []
    private(set) var editor: EditPropertyView?
    private var dropLine: NSView?
    var onClose: (() -> Void)?
    var onResize: (() -> Void)?
    /// Удаление свойства из «Изменить свойство»: вопрос задаёт презентер.
    var onDelete: ((DatabaseProperty) -> Void)?

    init(commands: PropertyMenuCommands) {
        self.commands = commands
        super.init(frame: .zero)
        stack.topPadding = 0
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = stack
        addSubview(scroll)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var contentHeight: CGFloat { min(stack.contentHeight, PropertyPopupMetrics.propertiesMaxHeight) }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        stack.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(stack.contentHeight, bounds.height))
    }

    /// Перечитать после правки базы.
    func reload() {
        if case .edit = screen, let editor {
            if !editor.reload() { show(.list) }
            return
        }
        guard screen == .list else { return }
        list = (try? PropertiesList.read(databaseId: commands.databaseId, store: commands.store)) ?? list
        rebuild()
    }

    private func show(_ next: Screen) {
        screen = next
        if next == .list { list = (try? PropertiesList.read(databaseId: commands.databaseId, store: commands.store)) ?? list }
        rebuild()
    }

    private func rebuild() {
        stack.removeAll()
        propertyRows = []
        editor = nil
        switch screen {
        case .list: buildList()
        case .edit(let id): buildEditor(id)
        case .new: buildNew()
        }
        needsLayout = true
        onResize?()
    }

    private func buildList() {
        let header = PropertyPopupHeader(title: "Свойства", showsBack: false)
        header.onClose = { [weak self] in self?.onClose?() }
        stack.append(header, height: PropertyPopupMetrics.headerHeight, inset: 0)
        for property in list.active {
            let row = PropertyRowWithHandle(property: property)
            row.onPress = { [weak self] in self?.show(.edit(property.id)) }
            row.onDragHandle = { [weak self] event in self?.drag(property.id, startingWith: event) }
            propertyRows.append((property.id, row))
            stack.append(row, height: PropertyPopupMetrics.rowHeight)
        }
        let add = PropertyPopupRow(title: "Новое свойство", icon: "plus", identifier: "properties-new")
        add.onPress = { [weak self] in self?.show(.new) }
        stack.append(add, height: PropertyPopupMetrics.rowHeight)
        guard !list.deleted.isEmpty else { return }
        stack.append(PropertyPopupSeparator(), height: PropertyPopupMetrics.separatorHeight)
        stack.append(PropertyPopupCaption("Удалённые свойства"), height: PropertyPopupMetrics.captionHeight)
        for property in list.deleted {
            let row = DeletedPropertyRow(property: property, canRestore: list.canRestore(property))
            row.onRestore = { [weak self] in
                guard let self else { return }
                PropertyMenuPresenter.attempt { try self.list.restore(property, operations: self.commands.operations) }
            }
            row.onErase = { [weak self] in
                guard let self else { return }
                PropertyMenuPresenter.attempt { try self.list.erase(property, operations: self.commands.operations) }
            }
            stack.append(row, height: PropertyPopupMetrics.rowHeight)
        }
    }

    private func buildEditor(_ id: UUID) {
        guard let property = list.active.first(where: { $0.id == id }) else { return show(.list) }
        let editor = EditPropertyView(property: property, commands: commands)
        editor.onBack = { [weak self] in self?.show(.list) }
        editor.onClose = { [weak self] in self?.onClose?() }
        editor.onDelete = { [weak self] property in self?.onDelete?(property) }
        editor.onResize = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.stack.setHeight(editor.contentHeight, of: editor)
            self.needsLayout = true
            self.onResize?()
        }
        self.editor = editor
        stack.append(editor, height: editor.contentHeight, inset: 0)
        editor.focusFirstField()
    }

    /// «Новое свойство» (`notion-edit-properties-new-property.png`): поле имени и типы одной колонкой; выбор типа создаёт
    /// свойство и открывает его «Изменить свойство».
    private func buildNew() {
        let header = PropertyPopupHeader(title: "Новое свойство")
        header.onBack = { [weak self] in self?.show(.list) }
        header.onClose = { [weak self] in self?.onClose?() }
        stack.append(header, height: PropertyPopupMetrics.headerHeight, inset: 0)
        let name = PropertyPopupField(text: "", placeholder: "Название свойства", icon: CellKind.for(.text).symbol, identifier: "properties-new-name")
        stack.append(name, height: PropertyPopupMetrics.nameBlockHeight)
        let commands = commands
        let chooser = PropertyTypeChooserView(columns: 1, current: nil, caption: "Тип") { query in
            (try? commands.typeRows(matching: query)) ?? []
        }
        chooser.list.onChoose = { [weak self, weak name] kind in
            guard let self else { return }
            var created: DatabaseProperty?
            PropertyMenuPresenter.attempt { created = try self.commands.addProperty(named: name?.text ?? "", kind: kind) }
            self.list = (try? PropertiesList.read(databaseId: commands.databaseId, store: commands.store)) ?? self.list
            self.show(created.map { .edit($0.id) } ?? .list)
        }
        chooser.onCancel = { [weak self] in self?.show(.list) }
        chooser.onResize = { [weak self, weak chooser] in
            guard let self, let chooser else { return }
            self.stack.setHeight(chooser.contentHeight, of: chooser)
            self.onResize?()
        }
        name.onCommand = { [weak chooser] command in chooser?.list.handle(command) ?? false }
        stack.append(chooser, height: chooser.contentHeight)
        DispatchQueue.main.async { [weak name] in name?.focus() }
    }

    // MARK: Перетаскивание ручкой

    /// Ведёт свойство за ручку до отпускания: синяя черта — место вставки; отпускание переставляет свойство.
    private func drag(_ propertyId: UUID, startingWith event: NSEvent) {
        guard let window else { return }
        var insertion: Int?
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = stack.convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp { break }
            insertion = insertionIndex(at: point.y)
            showDropLine(at: insertion)
        }
        showDropLine(at: nil)
        guard let insertion else { return }
        PropertyMenuPresenter.attempt { try list.move(propertyId, toInsertionIndex: insertion, operations: commands.operations) }
    }

    /// Место вставки (0…число свойств) по высоте точки в столбике.
    private func insertionIndex(at y: CGFloat) -> Int {
        let frames = propertyRows.map(\.view.frame)
        return frames.firstIndex { y < $0.midY } ?? frames.count
    }

    private func showDropLine(at insertion: Int?) {
        dropLine?.removeFromSuperview()
        dropLine = nil
        guard let insertion, let first = propertyRows.first?.view.frame else { return }
        let y = insertion < propertyRows.count ? propertyRows[insertion].view.frame.minY : (propertyRows.last?.view.frame.maxY ?? first.minY)
        let line = NSView(frame: NSRect(x: first.minX, y: y - 1, width: first.width, height: 2))
        line.wantsLayer = true
        line.layer?.backgroundColor = Palette.dropIndicator.cgColor
        stack.addSubview(line)
        dropLine = line
    }
}

/// Строка свойства окна «Свойства»: «⠿» (тянуть), значок типа, имя, «›».
@MainActor
final class PropertyRowWithHandle: NSView {
    private let row: PropertyPopupRow
    private let handle = NSImageView()
    var onPress: (() -> Void)? {
        get { row.onPress }
        set { row.onPress = newValue }
    }
    var onDragHandle: ((NSEvent) -> Void)?

    init(property: DatabaseProperty) {
        row = PropertyPopupRow(title: property.name, icon: CellKind.for(property.kind).symbol, showsChevron: true,
                               identifier: "properties-row-\(property.name)")
        super.init(frame: .zero)
        handle.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Перетащить")
        handle.contentTintColor = Palette.handleIcon
        handle.toolTip = "Перетащите, чтобы переставить"
        addSubview(row)
        addSubview(handle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private static let handleWidth: CGFloat = 20

    override func layout() {
        super.layout()
        handle.frame = NSRect(x: 4, y: (min(bounds.height, Metrics.ActionMenu.highlightHeight) - 14) / 2, width: 12, height: 14)
        row.frame = NSRect(x: Self.handleWidth, y: 0, width: bounds.width - Self.handleWidth, height: bounds.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return local.x < Self.handleWidth && bounds.contains(local) ? self : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) { onDragHandle?(event) }
}

/// Строка «Удалённых свойств»: значок, имя серым, «Вернуть» и «Удалить навсегда».
@MainActor
final class DeletedPropertyRow: NSView {
    private let name: String
    private let icon: String
    private let restore = NSButton()
    private let erase = NSButton()
    var onRestore: (() -> Void)?
    var onErase: (() -> Void)?

    init(property: DatabaseProperty, canRestore: Bool) {
        name = property.name
        icon = CellKind.for(property.kind).symbol
        super.init(frame: .zero)
        for (button, title, color, action) in [(restore, "Вернуть", Palette.textSecondary, #selector(restoreTapped)),
                                               (erase, "Удалить навсегда", Palette.destructiveText, #selector(eraseTapped))] {
            button.isBordered = false
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                                                   .foregroundColor: color])
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier("deleted-property-\(title)-\(property.name)")
            addSubview(button)
        }
        restore.isEnabled = canRestore
        if !canRestore { restore.toolTip = "В базе уже есть свойство ID" }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let height = min(bounds.height, Metrics.ActionMenu.highlightHeight)
        let eraseWidth = ceil(erase.attributedTitle.size().width) + 4
        let restoreWidth = ceil(restore.attributedTitle.size().width) + 4
        erase.frame = NSRect(x: bounds.maxX - PropertyPopupMetrics.padding - eraseWidth, y: (height - 18) / 2, width: eraseWidth, height: 18)
        restore.frame = NSRect(x: erase.frame.minX - 8 - restoreWidth, y: (height - 18) / 2, width: restoreWidth, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = min(bounds.height, Metrics.ActionMenu.highlightHeight)
        let side = Metrics.PopupMenu.iconSize
        ActionMenuIcon.draw(icon, color: Palette.textSecondary,
                            in: NSRect(x: PropertyPopupMetrics.padding, y: ((height - side) / 2).rounded(), width: side, height: side))
        let x = PropertyPopupMetrics.padding + side + Metrics.PopupMenu.iconToTitleSpacing
        let style = Typography.popupMenuTitle
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: name, attributes: [.font: style.font, .foregroundColor: Palette.textSecondary, .paragraphStyle: paragraph])
            .draw(in: NSRect(x: x, y: (height - style.lineHeight) / 2, width: max(0, restore.frame.minX - 8 - x), height: style.lineHeight))
    }

    @objc private func restoreTapped() { onRestore?() }
    @objc private func eraseTapped() { onErase?() }
}
