import AppKit
import Databases
import NotesCore
import VisualStyle

/// Настройки сводки в панели «Изменить свойство» (contracts/database-ui.md, `notion-rollup-edit-submenu.png`,
/// `notion-rollup-target-property.png`, `notion-rollup-calculate-menu.png`): «Связь ›» → «Свойство ›» (все свойства
/// связанной базы) → «Вычислить ›» (набор по типу свойства), внизу — «Изменения применяются ко всем видам с этим
/// свойством». Каждая правка — шаг ⌘Z; итоги всех строк пересчитываются в фоне.
@MainActor
final class RollupSettingsView: NSView {
    nonisolated static let settings = PropertyTypeSettings(kinds: [.rollup]) { RollupSettingsView(context: $0) }

    private let context: PropertyTypeSettingsContext
    private let stack = PropertyPopupStack()
    private let choices = PropertyChoiceCard()
    private(set) var relationRow: PropertyPopupRow!
    private(set) var targetRow: PropertyPopupRow!
    private(set) var calculationRow: PropertyPopupRow!

    init(context: PropertyTypeSettingsContext) {
        self.context = context
        super.init(frame: NSRect(x: 0, y: 0, width: PropertyPopupMetrics.panelWidth, height: 0))
        stack.topPadding = 0
        addSubview(stack)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { NSSize(width: frame.width, height: stack.contentHeight) }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    private var config: JSONValue { context.property.config }
    private var catalog: DatabaseCatalog? { try? DatabaseCatalog.read(context.property.databaseId, in: context.store) }

    private var relation: DatabaseProperty? {
        config["relationPropertyId"]?.string.flatMap(UUID.init(uuidString:)).flatMap { catalog?.propertiesById[$0] }
    }

    private var targetCatalog: DatabaseCatalog? {
        relation?.relationTarget.flatMap { try? DatabaseCatalog.read($0, in: context.store) }
    }

    private var target: DatabaseProperty? {
        config["targetPropertyId"]?.string.flatMap(UUID.init(uuidString:)).flatMap { targetCatalog?.propertiesById[$0] }
    }

    private var calculation: Calculation {
        config["calculation"]?.string.flatMap(Calculation.init(rawValue:)) ?? .showOriginal
    }

    private func build() {
        let relation = relation, target = target
        relationRow = PropertyPopupRow(title: "Связь", icon: "arrow.up.right", value: relation?.name ?? "Выбрать", showsChevron: true,
                                       identifier: "rollup-relation")
        relationRow.onPress = { [weak self] in self?.chooseRelation() }
        stack.append(relationRow, height: PropertyPopupMetrics.rowHeight)

        targetRow = PropertyPopupRow(title: "Свойство", icon: target.map { CellKind.for($0.kind).symbol } ?? "list.bullet",
                                     value: target?.name ?? "Выбрать", showsChevron: true, identifier: "rollup-target")
        targetRow.isEnabled = relation != nil
        targetRow.onPress = { [weak self] in self?.chooseTarget() }
        stack.append(targetRow, height: PropertyPopupMetrics.rowHeight)

        calculationRow = PropertyPopupRow(title: "Вычислить", icon: "sum", value: Self.title(of: calculation), showsChevron: true,
                                          identifier: "rollup-calculation")
        calculationRow.isEnabled = target != nil
        calculationRow.onPress = { [weak self] in self?.chooseCalculation() }
        stack.append(calculationRow, height: PropertyPopupMetrics.rowHeight)

        let note = NSTextField(wrappingLabelWithString: "Изменения применяются ко всем видам с этим свойством")
        note.font = Typography.popupMenuSectionHeader.font
        note.textColor = Palette.textSecondary
        note.setAccessibilityIdentifier("rollup-note")
        stack.append(note, height: 40)
    }

    // MARK: Выбор

    private func chooseRelation() {
        let current = relation?.id
        let relations = (catalog?.properties ?? []).filter { $0.kind == .relation }
        let items = relations.map { relation in
            PropertyChoiceCard.Item(title: relation.name, icon: "arrow.up.right", isChosen: relation.id == current,
                                    identifier: "rollup-relation-\(relation.id.uuidString.lowercased())") { [weak self] in
                // Другая связь — другая база: свойство цели выбирается заново.
                self?.save(relation: relation.id, target: relation.id == current ? self?.target?.id : nil, calculation: self?.calculation ?? .showOriginal)
            }
        }
        choices.show(caption: "Связь", items: items, besides: relationRow)
    }

    private func chooseTarget() {
        guard let relation, let targetCatalog else { return }
        let current = target?.id
        let items = targetCatalog.properties.map { property in
            PropertyChoiceCard.Item(title: property.name, icon: CellKind.for(property.kind).symbol, isChosen: property.id == current,
                                    identifier: "rollup-target-\(property.id.uuidString.lowercased())") { [weak self] in
                guard let self else { return }
                // Вычисление, которого у нового типа нет, — «Показать как есть».
                let calculation = Self.calculations(for: property.kind).contains { $0.1.contains(self.calculation) } ? self.calculation : .showOriginal
                self.save(relation: relation.id, target: property.id, calculation: calculation)
            }
        }
        choices.show(caption: "Свойство", items: items, besides: targetRow)
    }

    private func chooseCalculation() {
        guard let target else { return }
        let current = calculation
        var items: [PropertyChoiceCard.Item] = []
        for (section, calculations) in Self.calculations(for: target.kind) {
            for (index, calculation) in calculations.enumerated() {
                items.append(PropertyChoiceCard.Item(title: Self.title(of: calculation), icon: nil, isChosen: calculation == current,
                                                     identifier: "rollup-calculation-\(calculation.rawValue)",
                                                     section: index == 0 ? section : nil) { [weak self] in
                    self?.save(relation: self?.relation?.id, target: target.id, calculation: calculation)
                })
            }
        }
        choices.show(caption: nil, items: items, besides: calculationRow)
    }

    private func save(relation: UUID?, target: UUID?, calculation: Calculation) {
        do {
            try context.operations.setRollup(context.property.id, relation: relation, target: target, calculation: calculation)
        } catch {
            NSSound.beep()
        }
    }

    // MARK: Набор вычислений

    /// Вычисления сводки по типу свойства цели — разделами, как меню Notion «Calculate» (Show original, Show unique,
    /// Count ›, Percent ›, More options ›): у числа — числа, у даты — даты, у флажка — отметки.
    static func calculations(for kind: PropertyKind) -> [(String?, [Calculation])] {
        var sections: [(String?, [Calculation])] = [(nil, Calculation.rollupOnly), ("Количество", Array(Calculation.common.prefix(5))),
                                                    ("Проценты", Array(Calculation.common.suffix(2)))]
        switch kind {
        case .number, .formula, .rollup, .uniqueId: sections.append(("Ещё", Calculation.numeric))
        case .date, .createdTime, .lastEditedTime: sections.append(("Ещё", Calculation.dates))
        case .checkbox: sections.append(("Ещё", Calculation.checkbox))
        default: break
        }
        if kind == .formula || kind == .rollup { sections.append((nil, Calculation.dates)) }
        return sections
    }

    static func title(of calculation: Calculation) -> String {
        switch calculation {
        case .showOriginal: "Показать как есть"
        case .showUnique: "Показать уникальные"
        case .countAll: "Всего"
        case .countValues: "Значений"
        case .countUnique: "Уникальных значений"
        case .countEmpty: "Пустых"
        case .countNotEmpty: "Не пустых"
        case .percentEmpty: "Процент пустых"
        case .percentNotEmpty: "Процент не пустых"
        case .sum: "Сумма"
        case .average: "Среднее"
        case .median: "Медиана"
        case .min: "Минимум"
        case .max: "Максимум"
        case .range: "Размах"
        case .earliestDate: "Ранняя дата"
        case .latestDate: "Поздняя дата"
        case .dateRange: "Диапазон дат"
        case .checked: "Отмечено"
        case .unchecked: "Не отмечено"
        case .percentChecked: "Процент отмеченных"
        case .percentUnchecked: "Процент не отмеченных"
        }
    }
}
