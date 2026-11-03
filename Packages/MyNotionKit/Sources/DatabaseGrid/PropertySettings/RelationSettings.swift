import AppKit
import Databases
import NotesCore
import VisualStyle

/// Настройки связи в панели «Изменить свойство» (contracts/database-ui.md, `notion-edit-property-relation.png`,
/// `notion-relation-new-settings.png`): «Связана с» (база выбирается один раз, потом серым), «Лимит ›»
/// («1 страница» / «Без лимита»), «Ответное свойство» с переключателем и полем имени пары. Каждая правка — шаг ⌘Z.
@MainActor
final class RelationSettingsView: NSView {
    nonisolated static let settings = PropertyTypeSettings(kinds: [.relation]) { RelationSettingsView(context: $0) }
    static let limitTitles: [RelationLimit: String] = [.one: "1 страница", .none: "Без лимита"]

    private let context: PropertyTypeSettingsContext
    private var property: DatabaseProperty
    private let stack = PropertyPopupStack()
    private let choices = PropertyChoiceCard()
    private(set) var targetRow: PropertyPopupRow!
    private(set) var limitRow: PropertyPopupRow!
    private(set) var relatedSwitch: PropertySwitchRow!
    private(set) var relatedName: PropertyPopupField!

    init(context: PropertyTypeSettingsContext) {
        self.context = context
        property = context.property
        super.init(frame: NSRect(x: 0, y: 0, width: PropertyPopupMetrics.panelWidth, height: 0))
        stack.topPadding = 0
        addSubview(stack)
        build()
        watchChanges()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    // Панель «Изменить свойство» не пересобирается, пока в поле имени фокус: правку настроек (свою и с другого Mac)
    // раздел показывает сам.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    private func watchChanges() {
        observer = NotificationCenter.default.addObserver(forName: DatabaseOperations.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Перечитать свойство и собрать строки заново (высота раздела та же).
    func refresh() {
        guard let fresh = (try? context.store.write { try $0.property(property.id) }) ?? nil else { return }
        property = fresh
        stack.removeAll()
        build()
        needsLayout = true
    }
    override var fittingSize: NSSize { NSSize(width: frame.width, height: stack.contentHeight) }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }


    /// Пара связи, если она есть и не удалена.
    private var paired: DatabaseProperty? {
        guard let id = property.pairedRelation,
              let paired = try? context.store.write({ try $0.property(id) }) ?? nil, paired.deletedAt == nil else { return nil }
        return paired
    }

    private func build() {
        let state = (try? RelationLinks.targetState(of: property, in: context.store)) ?? .missing
        let isSet: Bool
        let value: String
        switch state {
        case .available(let title):
            isSet = true
            value = property.relationTarget == property.databaseId ? "Эта база" : (title.isEmpty ? Page.untitledTitle : title)
        case .trashed: (isSet, value) = (true, "База в корзине")
        case .erased: (isSet, value) = (true, "База удалена")
        case .missing: (isSet, value) = (false, "Выбрать")
        }
        targetRow = PropertyPopupRow(title: "Связана с", icon: "arrow.up.right", value: value, showsChevron: !isSet, identifier: "relation-target")
        // Базу связи не меняют (как Notion): выбрать можно, пока она не задана.
        targetRow.isEnabled = !isSet
        targetRow.onPress = { [weak self] in self?.chooseTarget() }
        stack.append(targetRow, height: PropertyPopupMetrics.rowHeight)

        limitRow = PropertyPopupRow(title: "Лимит", icon: "number", value: Self.limitTitles[property.relationLimit], showsChevron: true,
                                    identifier: "relation-limit")
        limitRow.onPress = { [weak self] in self?.chooseLimit() }
        stack.append(limitRow, height: PropertyPopupMetrics.rowHeight)

        let paired = paired
        let targetTitle = value
        relatedSwitch = PropertySwitchRow(title: "Ответное свойство", icon: "arrow.left.arrow.right", isOn: paired != nil,
                                          identifier: "relation-related-toggle")
        relatedSwitch.isEnabled = isSet && state != .erased
        relatedSwitch.setAccessibilityHelp("Показать связь в «\(targetTitle)»")
        relatedSwitch.onToggle = { [weak self] isOn in self?.setRelated(isOn) }
        stack.append(relatedSwitch, height: PropertyPopupMetrics.rowHeight)

        relatedName = PropertyPopupField(text: paired?.name ?? "", placeholder: "Имя ответного свойства", identifier: "relation-related-name")
        relatedName.isHidden = paired == nil
        relatedName.onEndEditing = { [weak self] text in self?.renameRelated(text) }
        stack.append(relatedName, height: PropertyPopupMetrics.nameBlockHeight)
    }

    // MARK: Правки

    private func chooseTarget() {
        let databases = (try? RelationLinks.databases(besides: property.databaseId, in: context.store)) ?? []
        let items = databases.map { database in
            PropertyChoiceCard.Item(title: database.id == property.databaseId ? "Эта база" : (database.title.isEmpty ? Page.untitledTitle : database.title),
                                    icon: "tablecells", isChosen: false, identifier: "relation-target-\(database.id.uuidString.lowercased())") { [weak self] in
                self?.setTarget(database.id)
            }
        }
        choices.show(caption: "Связать с базой", items: items, besides: targetRow)
    }

    private func setTarget(_ databaseId: UUID) {
        var config = currentConfig
        config["targetDatabaseId"] = .string(databaseId.databaseText)
        if config["limit"] == nil { config["limit"] = .string(RelationLimit.none.rawValue) }
        attempt { try context.operations.setPropertyConfig(property.id, config) }
    }

    private func chooseLimit() {
        let current = property.relationLimit
        let items = [RelationLimit.one, .none].map { limit in
            PropertyChoiceCard.Item(title: Self.limitTitles[limit]!, icon: nil, isChosen: limit == current,
                                    identifier: "relation-limit-\(limit.rawValue)") { [weak self] in
                guard let self else { return }
                self.attempt { try self.context.operations.setRelationLimit(self.property.id, limit) }
            }
        }
        choices.show(caption: nil, items: items, besides: limitRow)
    }

    private func setRelated(_ isOn: Bool) {
        attempt { try context.operations.setRelatedProperty(of: property.id, enabled: isOn) }
        // Пара — другое свойство: панель этого не перечитает, строки собираются заново (высота та же).
        stack.removeAll()
        build()
        needsLayout = true
        if !relatedName.isHidden { relatedName.focus() }
    }

    private func renameRelated(_ name: String) {
        guard let paired, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name != paired.name else { return }
        attempt { try context.operations.renameProperty(paired.id, to: name) }
    }

    /// Настройки — как сейчас в хранилище (панель могла жить дольше правки с другого Mac).
    private var currentConfig: JSONValue {
        ((try? context.store.write { try $0.property(property.id)?.config }) ?? nil) ?? property.config
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch { NSSound.beep() }
    }
}

// MARK: Общие виды настроек связи и сводки

/// Строка с переключателем справа (Notion «Add related property»).
@MainActor
final class PropertySwitchRow: NSView {
    private let row: PropertyPopupRow
    private let toggle = PopupSwitchTrack()
    var onToggle: ((Bool) -> Void)?
    var isOn: Bool {
        get { toggle.isOn }
        set { toggle.isOn = newValue }
    }
    var isEnabled = true {
        didSet {
            toggle.isEnabled = isEnabled
            row.isEnabled = isEnabled
        }
    }

    init(title: String, icon: String?, isOn: Bool, identifier: String) {
        row = PropertyPopupRow(title: title, icon: icon)
        super.init(frame: .zero)
        addSubview(row)
        toggle.isOn = isOn
        toggle.onChange = { [weak self] _ in self?.switched() }
        toggle.setIdentifier(identifier, label: title)
        addSubview(toggle)
        row.onPress = { [weak self] in
            guard let self, self.isEnabled else { return }
            self.isOn.toggle()
            self.switched()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        row.frame = bounds
        let size = PopupSwitchTrack.size
        toggle.frame = NSRect(x: bounds.maxX - PropertyPopupMetrics.padding - size.width,
                              y: ((min(bounds.height, Metrics.ActionMenu.highlightHeight) - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    @objc private func switched() { onToggle?(isOn) }
}

/// Маленькое окно выбора сбоку от строки (база связи, лимит, связь и свойство сводки, вычисление): строки с галочкой у
/// текущей, серые подписи разделов. Выбор закрывает окно.
@MainActor
final class PropertyChoiceCard {
    struct Item {
        var title: String
        var icon: String?
        var isChosen: Bool
        var identifier: String
        /// Подпись раздела над строкой («Количество», «Проценты»…).
        var section: String? = nil
        var action: () -> Void

        init(title: String, icon: String?, isChosen: Bool, identifier: String, section: String? = nil, action: @escaping () -> Void) {
            self.title = title
            self.icon = icon
            self.isChosen = isChosen
            self.identifier = identifier
            self.section = section
            self.action = action
        }
    }

    static let width: CGFloat = 240
    static let maxHeight: CGFloat = 420
    private let card = PopupCard()

    var isShown: Bool { card.isShown }

    func show(caption: String?, items: [Item], besides anchor: NSView) {
        let stack = PropertyPopupStack()
        if let caption { stack.append(PropertyPopupCaption(caption), height: PropertyPopupMetrics.captionHeight) }
        if items.isEmpty { stack.append(PropertyPopupCaption("Нет вариантов"), height: PropertyPopupMetrics.captionHeight) }
        for item in items {
            if let section = item.section { stack.append(PropertyPopupCaption(section), height: PropertyPopupMetrics.captionHeight) }
            let row = PropertyPopupRow(title: item.title, icon: item.icon, value: item.isChosen ? "✓" : nil, identifier: item.identifier)
            row.onPress = { [weak self] in
                self?.card.close()
                item.action()
            }
            stack.append(row, height: PropertyPopupMetrics.rowHeight)
        }
        let height = min(stack.contentHeight + 2 * Metrics.PopupMenu.verticalPadding, Self.maxHeight)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = stack.contentHeight + 2 * Metrics.PopupMenu.verticalPadding > Self.maxHeight
        scroll.autohidesScrollers = true
        let document = FlippedContainer(frame: NSRect(x: 0, y: 0, width: Self.width, height: stack.contentHeight + 2 * Metrics.PopupMenu.verticalPadding))
        stack.frame = document.bounds.insetBy(dx: PropertyPopupMetrics.inset, dy: Metrics.PopupMenu.verticalPadding)
        document.addSubview(stack)
        scroll.documentView = document
        card.show(scroll, size: scroll.frame.size, besides: anchor, gap: 0)
    }

    func close() { card.close() }

    private final class FlippedContainer: NSView {
        override var isFlipped: Bool { true }
    }
}

/// Переключатель окон свойства: включённый — синий, как у переключателей вида; выключенный — серый (Notion).
@MainActor
final class PopupSwitchTrack: NSView {
    static let size = NSSize(width: 30, height: 18)
    var onChange: ((Bool) -> Void)?
    var isOn = false { didSet { needsDisplay = true; setAccessibilityValue(isOn ? 1 : 0) } }
    var isEnabled = true { didSet { needsDisplay = true } }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    func setIdentifier(_ identifier: String, label: String) {
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
    }

    override func draw(_ dirtyRect: NSRect) {
        (isOn ? Palette.focusRing : Palette.switchOff).withAlphaComponent(isEnabled ? 1 : 0.5).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let knob = bounds.height - 4
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: isOn ? bounds.maxX - 2 - knob : 2, y: 2, width: knob, height: knob)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isOn.toggle()
        onChange?(isOn)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        isOn.toggle()
        onChange?(isOn)
        return true
    }
}
