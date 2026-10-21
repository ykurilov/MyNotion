import Foundation
import NotesCore

/// Смена типа свойства (contracts/property-types.md, «Смена типа»): значение строки в новом типе. Прежние значения
/// всех строк записывает шаг отмены операции (FR-318); здесь — только перевод одного значения.
public enum TypeChange {
    public enum Result: Sendable, Hashable {
        case value(JSONValue?)
        /// Названия вариантов по порядку: операция находит или создаёт их (цвета по кругу) и пишет id.
        case optionNames([String])
    }

    static let optionKinds: Set<PropertyKind> = [.select, .multiSelect, .status]
    /// Типы, в которые значения не переносятся: прежние хранятся до ⌘Z.
    static let derivedKinds: Set<PropertyKind> = [.title, .relation, .rollup, .formula, .createdTime, .lastEditedTime, .uniqueId]

    public static func convert(_ value: JSONValue?, from source: PropertyContext, to target: PropertyContext) -> Result {
        let targetKind = target.property.kind
        guard let value, value != .null, !derivedKinds.contains(targetKind) else { return .value(nil) }
        let sourceType = PropertyTypes.type(for: source.property.kind)
        if optionKinds.contains(source.property.kind), optionKinds.contains(targetKind) {
            let names = (value.array ?? [value]).compactMap { source.option($0)?.option.name }
            return .optionNames(targetKind == .multiSelect ? names : Array(names.prefix(1)))
        }
        // «Текст показа» источника; у связи — названия строк.
        let text = source.property.kind == .relation ? sourceType.displayText(value, in: source) : sourceType.csvText(value, in: source)
        if optionKinds.contains(targetKind) {
            let names = targetKind == .multiSelect
                ? text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : [text.trimmingCharacters(in: .whitespaces)].filter { !$0.isEmpty }
            return names.isEmpty ? .value(nil) : .optionNames(names)
        }
        switch PropertyTypes.type(for: targetKind).parseCSV(text, in: target) {
        case .value(let converted): return .value(converted)
        case .options(let names): return .optionNames(names)
        }
    }
}
