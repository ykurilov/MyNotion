import AppKit
import Databases
import NotesCore
import VisualStyle

/// Вход сетки и страницы строки в окна свойства (US1, contracts/database-ui.md): меню колонки, «+» (новое свойство),
/// панель «Изменить свойство» справа и окно «Свойства» базы. Окна — карточки всплывающих меню 002 (`PopupCard`);
/// после правки базы (`DatabaseOperations.didChange`) открытые окна перечитывают свойство.
@MainActor
public final class PropertyMenuPresenter {
    let commands: PropertyMenuCommands
    private let menuCard = PopupCard()
    private let submenuCard = PopupCard()
    private let confirmCard = PopupCard()
    private let propertiesCard = PopupCard()
    private(set) var columnMenu: ColumnMenuView?
    private(set) var editPanel: EditPropertyPanel?
    private(set) var propertiesWindow: PropertiesWindowView?
    private var anchorView: NSView?
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    /// Где встаёт панель «Изменить свойство» из меню колонки; `nil` — вид, у которого открыто меню.
    public weak var panelHost: NSView?
    /// Рамка шапки колонки свойства в координатах вида, где открыто меню: под ней — окно новой колонки.
    public var columnRect: ((UUID) -> NSRect?)?

    public init(store: NotesStore, operations: DatabaseOperations, databaseId: UUID, viewId: UUID?) {
        commands = PropertyMenuCommands(store: store, operations: operations, databaseId: databaseId, viewId: viewId)
        observer = NotificationCenter.default.addObserver(forName: DatabaseOperations.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.databaseDidChange() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        // Overlay принадлежит презентеру таблицы: смена страницы освобождает его вместе с монитором.
        editPanel?.stopWatching()
        editPanel?.removeFromSuperview()
    }

    // MARK: Меню колонки

    /// Щелчок по шапке колонки: меню под `rect` (координаты `view`), левым краем по нему.
    public func showColumnMenu(for propertyId: UUID, below rect: NSRect, in view: NSView) {
        guard let property = property(propertyId) else { return }
        anchorView = view
        let menu = ColumnMenuView(property: property, entries: commands.entries(for: property)) { [weak self] slot, row in
            self?.choose(slot, for: propertyId, row: row)
        }
        menu.onCommitName = { [weak self] name in self?.rename(propertyId, to: name) }
        menu.onDismiss = { [weak self] in self?.menuCard.close() }
        menuCard.onClose = { [weak self, weak menu] in
            // Щелчок мимо тоже сохраняет имя.
            if let menu { self?.rename(propertyId, to: menu.nameField.text) }
            self?.submenuCard.close()
            self?.columnMenu = nil
        }
        columnMenu = menu
        show(menu, size: menu.fittingSize, in: menuCard, below: rect, of: view)
        menu.nameField.focus()
    }

    private func choose(_ slot: PropertyMenuSlot, for propertyId: UUID, row: NSView) {
        guard let property = property(propertyId) else { return }
        var outcome = PropertyMenuOutcome.done
        if slot != .changeType { saveMenuName() }
        Self.attempt { outcome = try commands.perform(slot, on: property) }
        switch outcome {
        case .openTypeList:
            showChangeType(for: property, besides: row)
        case .openEditPanel:
            menuCard.close()
            guard let host = panelHost ?? anchorView else { return }
            showEditProperty(propertyId, in: host)
        case .confirmDelete:
            menuCard.close()
            confirmDelete(property)
        case .configureNew(let newId):
            menuCard.close()
            guard let view = anchorView, let rect = columnRect?(newId), let created = self.property(newId) else { return }
            showNewColumn(created, below: rect, in: view)
        case .done:
            menuCard.close()
        }
    }

    /// «Сменить тип ›»: список типов в две колонки сбоку от пункта; выбор меняет тип и закрывает меню.
    private func showChangeType(for property: DatabaseProperty, besides row: NSView) {
        let commands = commands
        let chooser = PropertyTypeChooserView(columns: 2, current: property.kind, caption: nil) { query in
            (try? commands.typeRows(current: property, matching: query)) ?? []
        }
        chooser.list.onChoose = { [weak self] kind in
            guard let self else { return }
            Self.attempt { try self.commands.changeType(property, to: kind) }
            self.menuCard.close()
        }
        chooser.onCancel = { [weak self] in
            self?.submenuCard.close()
            self?.columnMenu?.nameField.focus()
        }
        let container = PaddedPopupContent(chooser) { chooser.contentHeight }
        chooser.onResize = { [weak self, weak container] in
            guard let self, let container else { return }
            self.submenuCard.show(container, size: container.fittingSize, besides: row, gap: 0)
            chooser.search.focus()
        }
        submenuCard.show(container, size: container.fittingSize, besides: row, gap: 0)
        chooser.search.focus()
    }

    // MARK: «+»

    /// «+» в шапке и «+ Добавить свойство» страницы строки: поле «Название свойства…» и типы в две колонки с поиском;
    /// выбор типа создаёт свойство (колонка — в конце видов) и закрывает окно.
    public func showAddProperty(below rect: NSRect, in view: NSView) {
        showNameAndType(below: rect, in: view, name: "", current: nil) { [weak self] name, kind in
            guard let self, let kind else { return }
            var created: DatabaseProperty?
            Self.attempt { created = try self.commands.addProperty(named: name, kind: kind) }
            // Связь и сводка без настроек пусты: панель «Изменить свойство» — сразу (contracts/property-types.md).
            if let created, kind == .relation || kind == .rollup, let host = self.panelHost ?? self.anchorView {
                self.showEditProperty(created.id, in: host)
            }
        }
    }

    /// «Вставить слева / справа»: под новой колонкой — её имя (выделено) и типы; выбор типа меняет его, Enter без
    /// выбора оставляет «Текст».
    func showNewColumn(_ property: DatabaseProperty, below rect: NSRect, in view: NSView) {
        showNameAndType(below: rect, in: view, name: property.name, current: property.kind) { [weak self] name, kind in
            guard let self, let current = self.property(property.id) else { return }
            Self.attempt { try self.commands.rename(current, to: name) }
            if let kind, kind != current.kind, let renamed = self.property(property.id) {
                Self.attempt { try self.commands.changeType(renamed, to: kind) }
            }
        }
    }

    /// Окно «имя и тип»: `finish` получает имя и выбранный тип (`nil` — Enter без выбора у существующего свойства).
    private func showNameAndType(below rect: NSRect, in view: NSView, name initialName: String, current: PropertyKind?,
                                 finish: @escaping (String, PropertyKind?) -> Void) {
        anchorView = view
        let name = PropertyPopupField(text: initialName, placeholder: "Название свойства…", icon: "face.smiling", identifier: "add-property-name")
        let commands = commands
        let chooser = PropertyTypeChooserView(columns: 2, current: current, caption: "Тип") { query in
            (try? commands.typeRows(matching: query)) ?? []
        }
        chooser.list.onChoose = { [weak self, weak name] kind in
            guard let self else { return }
            finish(name?.text ?? "", kind)
            self.menuCard.close()
        }
        chooser.onCancel = { [weak self] in self?.menuCard.close() }
        name.onCommand = { [weak self, weak chooser] command in
            guard let self, let chooser else { return false }
            switch command {
            case #selector(NSResponder.cancelOperation(_:)):
                self.menuCard.close()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                // Enter без выбранного типа — «Текст» у нового, прежний тип у вставленной колонки.
                if !chooser.list.handle(command) { chooser.list.onChoose?(current ?? .text) }
                return true
            default:
                return chooser.list.handle(command)
            }
        }
        let stack = PropertyPopupStack()
        stack.append(name, height: PropertyPopupMetrics.nameBlockHeight)
        stack.append(PropertyPopupSeparator(), height: PropertyPopupMetrics.separatorHeight)
        stack.append(chooser, height: chooser.contentHeight)
        let size = { NSSize(width: PropertyPopupMetrics.typeGridWidth, height: stack.contentHeight) }
        chooser.onResize = { [weak self, weak stack, weak chooser] in
            guard let self, let stack, let chooser else { return }
            stack.setHeight(chooser.contentHeight, of: chooser)
            self.show(stack, size: size(), in: self.menuCard, below: rect, of: view)
            name.focus()
        }
        menuCard.onClose = nil
        show(stack, size: size(), in: menuCard, below: rect, of: view)
        name.focus()
    }

    // MARK: Панель «Изменить свойство»

    /// Панель справа в `host` на всю его высоту (≈ 280): «← Изменить свойство ×», имя, «Тип ›», настройки типа,
    /// «Дублировать», «Удалить». Esc, «×», «←» и щелчок мимо закрывают.
    public func showEditProperty(_ propertyId: UUID, in host: NSView) {
        guard let property = property(propertyId) else { return }
        closeEditPanel()
        let editor = EditPropertyView(property: property, commands: commands)
        let panel = EditPropertyPanel(editor: editor)
        editor.onBack = { [weak self] in self?.closeEditPanel() }
        editor.onClose = { [weak self] in self?.closeEditPanel() }
        editor.onDelete = { [weak self] property in self?.confirmDelete(property) }
        panel.onCancel = { [weak self] in self?.closeEditPanel() }
        // Короткая таблица не ограничивает hit-test панели: настройки числа могут быть выше всей таблицы.
        // Overlay живёт в содержимом окна; длинный редактор прокручивается внутри доступной высоты.
        let container = host.window?.contentView ?? host
        let place: @MainActor @Sendable () -> Void = { [weak host, weak container, weak panel] in
            guard let host, let container, let panel else { return }
            // NSView.clipsToBounds по умолчанию false: visibleRect может выходить за собственные bounds.
            let visible = host.visibleRect.intersection(host.bounds)
            let anchor = host.convert(visible, to: container).intersection(container.bounds)
            guard !anchor.isEmpty else { return }
            let width = min(PropertyPopupMetrics.panelWidth, anchor.width)
            let available = container.isFlipped ? container.bounds.maxY - anchor.minY : anchor.maxY - container.bounds.minY
            let height = min(max(0, available - 8), max(anchor.height, panel.editor.contentHeight))
            let y = container.isFlipped ? anchor.minY : anchor.maxY - height
            let frame = NSRect(x: anchor.maxX - width, y: y, width: width, height: height)
            if panel.frame != frame {
                panel.frame = frame
                panel.needsLayout = true
            }
        }
        panel.autoresizingMask = [.minXMargin, .height]
        container.addSubview(panel, positioned: .above, relativeTo: nil)
        editor.onResize = { [weak panel] in
            place()
            panel?.needsLayout = true
        }
        place()
        panel.watchOutsideClicks(anchor: host, onResize: place)
        editPanel = panel
        editor.focusFirstField()
    }

    private func closeEditPanel() {
        editPanel?.stopWatching()
        editPanel?.removeFromSuperview()
        editPanel = nil
    }

    // MARK: Окно «Свойства»

    /// Окно «Свойства» базы под `rect` (из настроек вида): свойства с ручками, «+ Новое свойство», «Удалённые свойства».
    public func showPropertiesWindow(below rect: NSRect, in view: NSView) {
        anchorView = view
        let window = PropertiesWindowView(commands: commands)
        window.onClose = { [weak self] in self?.propertiesCard.close() }
        window.onDelete = { [weak self] property in self?.confirmDelete(property) }
        let size = { [weak window] in NSSize(width: PropertyPopupMetrics.propertiesWidth, height: window?.contentHeight ?? 0) }
        window.onResize = { [weak self, weak window] in
            guard let self, let window, self.propertiesCard.isShown else { return }
            self.show(window, size: size(), in: self.propertiesCard, below: rect, of: view)
            window.editor?.focusFirstField()
        }
        propertiesCard.onClose = { [weak self] in self?.propertiesWindow = nil }
        propertiesWindow = window
        show(window, size: size(), in: propertiesCard, below: rect, of: view)
    }

    // MARK: Удаление

    /// «Удалить это свойство из «База»? Оно пропадёт из всех видов.» [Удалить] [Отмена] — по центру окна
    /// (меню колонки, панель; галерея — после `showColumnMenu`).
    public func confirmDelete(_ property: DatabaseProperty) {
        guard let view = editPanel ?? anchorView, let content = view.window?.contentView else { return }
        var question = ""
        Self.attempt { question = try commands.deleteQuestion() }
        let confirm = DeletePropertyConfirmView(question: question)
        confirm.onCancel = { [weak self] in self?.confirmCard.close() }
        confirm.onConfirm = { [weak self] in
            guard let self else { return }
            self.confirmCard.close()
            Self.attempt { try self.commands.delete(property) }
        }
        let size = NSSize(width: PropertyPopupMetrics.confirmWidth, height: confirm.fittingHeight)
        // Под вопросом окно затемнено, как у Notion; щелчок по затемнению — «Отмена».
        let dimming = PopupDimmingView(frame: content.bounds)
        dimming.autoresizingMask = [.width, .height]
        dimming.onClick = { [weak self] in self?.confirmCard.close() }
        content.addSubview(dimming)
        confirmCard.onClose = { [weak dimming] in dimming?.removeFromSuperview() }
        let point = NSPoint(x: content.bounds.midX - size.width / 2, y: content.bounds.midY + size.height / 2)
        confirmCard.show(confirm, size: size, from: content.convert(point, to: nil), in: content)
        confirm.window?.makeFirstResponder(confirm)
    }

    // MARK: Общее

    /// Закрыть все окна свойства.
    public func close() {
        menuCard.close()
        submenuCard.close()
        confirmCard.close()
        propertiesCard.close()
        closeEditPanel()
    }

    private func databaseDidChange() {
        if let editPanel, !editPanel.editor.reload() { closeEditPanel() }
        propertiesWindow?.reload()
    }

    private func property(_ id: UUID) -> DatabaseProperty? {
        try? DatabaseCatalog.read(commands.databaseId, in: commands.store).propertiesById[id]
    }

    private func rename(_ propertyId: UUID, to name: String) {
        guard let property = property(propertyId) else { return }
        Self.attempt { try commands.rename(property, to: name) }
    }

    private func saveMenuName() {
        guard let menu = columnMenu else { return }
        rename(menu.propertyId, to: menu.nameField.text)
    }

    /// Карточка `content` размером `size` под `rect` (координаты `view`), левым краем по нему.
    private func show(_ content: NSView, size: NSSize, in card: PopupCard, below rect: NSRect, of view: NSView) {
        let anchor = view.convert(rect, to: nil)
        let point = NSPoint(x: anchor.minX, y: anchor.minY - Metrics.PopupMenu.anchorSpacing)
        guard let windowContent = view.window?.contentView else { return }
        card.show(content, size: size, from: windowContent.convert(point, from: nil), in: windowContent)
    }

    /// Правка базы: ошибка операции (например, второе ID с другого Mac) — звуком, окно остаётся.
    static func attempt(_ body: () throws -> Void) {
        do { try body() } catch { NSSound.beep() }
    }
}

/// Карточка с полями 6 сверху и снизу и 4 по бокам вокруг содержимого переменной высоты.
@MainActor
final class PaddedPopupContent: NSView {
    private let content: NSView
    private let height: () -> CGFloat

    init(_ content: NSView, height: @escaping () -> CGFloat) {
        self.content = content
        self.height = height
        super.init(frame: .zero)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        NSSize(width: PropertyPopupMetrics.typeGridWidth, height: height() + 2 * Metrics.PopupMenu.verticalPadding)
    }

    override func layout() {
        super.layout()
        content.frame = bounds.insetBy(dx: PropertyPopupMetrics.inset, dy: Metrics.PopupMenu.verticalPadding)
    }
}

/// Панель «Изменить свойство» у правого края таблицы: фон страницы, черта слева.
@MainActor
final class EditPropertyPanel: NSView {
    let editor: EditPropertyView
    private let scroll = NSScrollView()
    var onCancel: (() -> Void)?
    private var monitor: Any?
    private var resizeObserver: NSObjectProtocol?
    private var updateObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?

    init(editor: EditPropertyView) {
        self.editor = editor
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        addSubview(scroll)
        setAccessibilityIdentifier("edit-property-panel")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 1, y: 0, width: max(0, bounds.width - 1), height: bounds.height)
        editor.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(bounds.height, editor.contentHeight))
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.pageBackground.setFill()
        bounds.fill()
        Palette.border.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    /// Щелчок под панелью не уходит в таблицу.
    override func mouseDown(with event: NSEvent) {}

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Щелчок мимо панели в её окне закрывает её (окна-карточки — другие окна, их щелчки не считаются).
    func watchOutsideClicks(anchor: NSView, onResize: @escaping @MainActor () -> Void = {}) {
        // Редактор может кэшировать вид прежней базы: исчезновение anchor из окна тоже закрывает overlay.
        updateObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self, weak anchor] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let anchor, anchor.window === self.window, !anchor.isHiddenOrHasHiddenAncestor else {
                    self.onCancel?()
                    return
                }
                onResize()
            }
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onCancel?() }
        }
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { onResize() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.onCancel?() }
            return event
        }
    }

    func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
        updateObserver = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }
}

/// Затемнение окна под вопросом (Notion 7.39, `notion-delete-property-confirm.png`).
@MainActor
final class PopupDimmingView: NSView {
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("popup-dimming")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func draw(_ dirtyRect: NSRect) {
        Palette.modalBackdrop.setFill()
        dirtyRect.fill()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
