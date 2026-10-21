import Databases
import Formulas
import Foundation
import NotesCore

/// Что показывает редактор формулы (contracts/formulas.md, «Редактор», `notion-formula-editor*.png`): проверка текста,
/// итог для строки-примера, «Тип: …», список свойств и функций по разделам с поиском по набранному слову и описание
/// выбранного. Вид — `FormulaEditorView`; модель от вида не зависит и проверяется тестами.
@MainActor
public final class FormulaEditorModel {
    /// Строка для «Предпросмотр с <строка ▾>».
    public struct PreviewRow: Sendable, Hashable {
        public let id: UUID
        public let title: String
    }

    /// Пункт списка слева.
    public enum Item: Sendable, Hashable {
        case property(FormulaProperty, kind: PropertyKind)
        case builtin(String)
        case function(String)

        public var title: String {
            switch self {
            case .property(let property, _): property.name
            case .builtin(let symbol): symbol
            case .function(let name): name + "()"
            }
        }
    }

    public struct Section: Sendable, Hashable {
        public let title: String
        public let items: [Item]
    }

    /// Описание справа: заголовок, синтаксис, текст и примеры с итогом.
    public struct Description: Sendable, Hashable {
        public let title: String
        public let summary: String
        public let examples: [FormulaExample]
    }

    public let store: NotesStore
    public let property: DatabaseProperty
    public let schema: DatabaseFormulaSchema
    public let previewRows: [PreviewRow]
    let kinds: [String: PropertyKind]
    let now: () -> Date

    /// Текст Юрия (с названиями свойств).
    public private(set) var text: String
    /// Каретка в символах.
    public private(set) var caret: Int
    public var previewRow: PreviewRow? { didSet { updatePreview() } }
    /// Итог проверки; `nil` — пусто.
    public private(set) var check: Result<FormulaCheck, FormulaError>?
    public private(set) var preview: Result<FormulaPreview.Output, FormulaError>?
    public private(set) var sections: [Section] = []
    public var selected: Item?
    /// Текст в начале — чтобы «Отменить изменения».
    public let originalText: String

    public init(store: NotesStore, property: DatabaseProperty, rows: [UUID], now: @escaping () -> Date = Date.init) throws {
        self.store = store
        self.property = property
        self.now = now
        schema = try DatabaseFormulaSchema.read(property.databaseId, in: store)
        kinds = Dictionary(uniqueKeysWithValues: (try DatabaseCatalog.read(property.databaseId, in: store)).properties.map { ($0.id.databaseText, $0.kind) })
        let firstRows = Array(rows.prefix(50))
        let titles = try store.write { tx in try Dictionary(uniqueKeysWithValues: firstRows.map { ($0, try tx.page($0)?.title ?? "") }) }
        previewRows = firstRows.map { PreviewRow(id: $0, title: titles[$0].flatMap { $0.isEmpty ? nil : $0 } ?? Page.untitledTitle) }
        previewRow = previewRows.first
        let stored = property.config["expression"]?.string ?? ""
        text = stored.isEmpty ? "" : FormulaSource.display(stored, schema: schema)
        originalText = text
        caret = text.count
        update()
    }

    var owner: FormulaProperty { DatabaseFormulaSchema.formulaProperty(property) }

    /// Новый текст и каретка (после каждого изменения поля).
    public func edit(_ text: String, caret: Int) {
        self.text = text
        self.caret = caret
        update()
    }

    /// Каретка сдвинулась без правки: список ищет по слову перед ней.
    public func moveCaret(_ caret: Int) {
        self.caret = caret
        updateList()
    }

    private func update() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            check = nil
        } else {
            do { check = .success(try FormulaTypeChecker.check(text, schema: schema, owner: owner)) } catch { check = .failure(error) }
        }
        updatePreview()
        updateList()
    }

    private func updatePreview() {
        guard case .success? = check, let row = previewRow, let stored = try? FormulaSource.stored(text, schema: schema, owner: owner) else {
            preview = nil
            return
        }
        preview = FormulaPreview.evaluate(stored, row: row.id, databaseId: property.databaseId, store: store, now: now())
    }

    // MARK: Что показать

    /// «Готово» неактивно, пока есть ошибка разбора, типов или круг (contracts, «Редактор»).
    public var canSave: Bool { if case .failure? = check { false } else { true } }

    public var isChanged: Bool { text != originalText }

    /// Ошибка: текст и место (символы) для подчёркивания.
    public var error: FormulaError? {
        if case .failure(let error)? = check { return error }
        if case .failure(let error)? = preview { return error }
        return nil
    }

    /// «Тип: число»; без итога — «Тип: неизвестно».
    public var typeLabel: String {
        guard case .success(let check)? = check else { return "Тип: неизвестно" }
        return "Тип: " + check.type.name
    }

    /// Итог для строки-примера или «Нет итога».
    public var outputText: String {
        if case .success(let output)? = preview, !output.text.isEmpty { return output.text }
        return "Нет итога"
    }

    /// Свойства, на которые ссылается текст (для плашек): место `prop("…")` и свойство.
    public var propertyChips: [(range: Range<Int>, property: FormulaProperty, kind: PropertyKind)] {
        FormulaHighlight.propertyCalls(text).compactMap { call in
            let database: String? = isForeign(call) ? relatedDatabase(of: call) : nil
            guard let property = schema.property(call.key, inDatabase: database) ?? (database == nil ? nil : schema.property(call.key, inDatabase: nil))
            else { return nil }
            return (call.range, property, kinds[property.id] ?? .text)
        }
    }

    /// `current.prop("…")` — свойство строки из связи.
    private func isForeign(_ call: FormulaHighlight.PropertyCall) -> Bool {
        let characters = Array(text)
        return call.range.lowerBound > 0 && characters[call.range.lowerBound - 1] == "."
    }

    /// База для `current.prop("…")`: по ссылкам проверки.
    private func relatedDatabase(of call: FormulaHighlight.PropertyCall) -> String? {
        guard case .success(let check)? = check else { return nil }
        let literal = (call.range.lowerBound + 5)..<(call.range.upperBound - 1)
        guard let reference = check.references.first(where: { $0.range == literal }) else { return nil }
        return schema.databaseId(ofProperty: reference.property.id)?.databaseText
    }

    // MARK: Список и описание

    /// Слово перед кареткой — поиск по списку.
    public var searchWord: String { FormulaHighlight.word(before: caret, in: text).text }

    private func updateList() {
        let word = searchWord.lowercased()
        func matches(_ name: String) -> Bool { word.isEmpty || name.lowercased().contains(word) }
        var result: [Section] = []
        let properties = schema.properties.filter { $0.id != owner.id && matches($0.name) }
            .map { Item.property($0, kind: kinds[$0.id] ?? .text) }
        if !properties.isEmpty { result.append(Section(title: "Свойства", items: properties)) }
        let builtins = FormulaFunctionCatalog.builtins.filter { word.isEmpty || $0.symbol.lowercased().hasPrefix(word) }.map { Item.builtin($0.symbol) }
        if !builtins.isEmpty { result.append(Section(title: "Встроенные", items: builtins)) }
        for section in FormulaSection.allCases {
            let functions = FormulaFunctionCatalog.functions(in: section).filter { $0.name != "prop" && matches($0.name) }.map { Item.function($0.name) }
            if !functions.isEmpty { result.append(Section(title: section.rawValue, items: functions)) }
        }
        sections = result
        let all = result.flatMap(\.items)
        if selected.map({ !all.contains($0) }) ?? true { selected = all.first }
    }

    public func description(of item: Item) -> Description {
        switch item {
        case .property(let property, let kind):
            let call = "prop(" + FormulaSource.quoted(property.name) + ")"
            return Description(title: property.name, summary: "Свойство «\(PropertyKindNames.title(kind))».", examples: [FormulaExample(call, "")])
        case .builtin(let symbol):
            let builtin = FormulaFunctionCatalog.builtins.first { $0.symbol == symbol }
            return Description(title: symbol, summary: builtin?.summary ?? "", examples: builtin?.examples ?? [])
        case .function(let name):
            let info = FormulaFunctionCatalog.byName[name]
            return Description(title: info?.syntax ?? name, summary: info?.summary ?? "", examples: info?.examples ?? [])
        }
    }

    /// Текст пункта для вставки и место каретки в нём: у функции с аргументами — между скобками.
    public func insertion(for item: Item) -> (text: String, caretShift: Int) {
        switch item {
        case .property(let property, _):
            let text = "prop(" + FormulaSource.quoted(property.name) + ")"
            return (text, text.count)
        case .builtin(let symbol):
            if symbol == "? :" { return (" ? : ", 3) }
            let text = symbol.first!.isLetter ? symbol : " \(symbol) "
            return (text, text.count)
        case .function(let name):
            let takesArguments = !(FormulaFunctionCatalog.byName[name]?.syntax.hasSuffix("()") ?? false)
            return (name + "()", takesArguments ? name.count + 1 : name.count + 2)
        }
    }

    /// Вставка пункта вместо слова перед кареткой: новый текст и каретка.
    public func inserting(_ item: Item) -> (text: String, caret: Int) {
        let word = FormulaHighlight.word(before: caret, in: text)
        let insertion = insertion(for: item)
        var characters = Array(text)
        characters.replaceSubrange(word.range, with: Array(insertion.text))
        return (String(characters), word.range.lowerBound + insertion.caretShift)
    }

    /// «Готово»: проверка и запись операцией с шагом ⌘Z.
    public func save(using operations: DatabaseOperations) throws {
        try operations.setFormula(property.id, display: text)
    }
}

/// Названия типов по-русски для описаний (как в списке типов, `CellKind`).
enum PropertyKindNames {
    static func title(_ kind: PropertyKind) -> String { CellKind.for(kind).title }
}
