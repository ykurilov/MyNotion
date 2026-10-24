import Databases
import Foundation
import NotesCore

/// Текст значений базы как у Notion (contracts/sync-v4-and-export.md): число без разделителей групп, даты по-английски,
/// флажок `Yes` / `No`, списки через `, `, связь — `Название (путь к файлу строки)`, формула и сводка — итогом.
/// Тексты считаются один раз на строку — для CSV и для Markdown строки; у связи текст зависит от того, откуда путь.
struct DatabaseValueText: Sendable {
    let snapshot: DatabaseExportSnapshot
    /// Колонки CSV по порядку (`DatabaseExportSnapshot.columns`).
    let columns: [DatabaseProperty]
    private let contexts: [UUID: PropertyContext]
    /// Строка или шаблон → тексты колонок (у связи — пусто: её пишет `text(at:of:relation:)`).
    private let texts: [UUID: [String]]

    init(snapshot: DatabaseExportSnapshot) {
        self.snapshot = snapshot
        let catalog = snapshot.catalog
        let contexts = Dictionary(uniqueKeysWithValues: catalog.properties.map { ($0.id, catalog.context(for: $0)) })
        self.contexts = contexts
        let columns = snapshot.columns
        self.columns = columns
        var texts: [UUID: [String]] = [:]
        for row in snapshot.rows + snapshot.templates {
            texts[row.id] = columns.map { $0.kind == .relation ? "" : Self.text($0, of: row, snapshot: snapshot, contexts: contexts) }
        }
        self.texts = texts
    }

    /// Текст колонки `index`; `relation` — текст одной связанной строки (`Название (путь)`).
    func text(at index: Int, of row: Page, relation: (UUID) -> String) -> String {
        let property = columns[index]
        if property.kind == .relation {
            return (snapshot.relations[row.id]?[property.id] ?? []).map(relation).joined(separator: ", ")
        }
        return texts[row.id]?[index] ?? Self.text(property, of: row, snapshot: snapshot, contexts: contexts)
    }

    private static func text(_ property: DatabaseProperty, of row: Page, snapshot: DatabaseExportSnapshot,
                             contexts: [UUID: PropertyContext]) -> String {
        let context = contexts[property.id] ?? PropertyContext(property: property)
        let type = PropertyTypes.type(for: property.kind)
        switch property.kind {
        case .title: return row.title
        case .createdTime: return type.csvText(PropertyValue.pageDate(row.createdAt, in: context), in: context)
        case .lastEditedTime: return type.csvText(PropertyValue.pageDate(row.updatedAt, in: context), in: context)
        case .relation: return ""
        case .formula, .rollup: return type.csvText(snapshot.computed[row.id]?[property.id], in: context)
        default: return type.csvText(snapshot.cells[row.id]?[property.id] ?? nil, in: context)
        }
    }

    func title(ofTarget id: UUID) -> String {
        let title = snapshot.targetTitles[id] ?? ""
        return title.isEmpty ? Page.untitledTitle : title
    }
}

/// CSV базы (как `_all.csv` Notion 7.39): UTF-8 с BOM, запятая, кавычки RFC 4180; первая колонка — название,
/// дальше колонки первого вида (и скрытые), затем остальные свойства; все строки по порядку.
enum DatabaseCSVWriter {
    /// `relationPath` — путь файла строки-цели от папки CSV; `nil` — строки нет в выгрузке.
    static func csv(_ snapshot: DatabaseExportSnapshot, values: DatabaseValueText, relationPath: (UUID) -> String?) -> String {
        let columns = values.columns
        func relation(_ id: UUID) -> String {
            let title = values.title(ofTarget: id)
            return relationPath(id).map { "\(title) (\($0))" } ?? title
        }
        var lines = [columns.map { field($0.name) }.joined(separator: ",")]
        for row in snapshot.rows {
            lines.append(columns.indices.map { field(values.text(at: $0, of: row, relation: relation)) }.joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
    }

    /// Поле RFC 4180: в кавычках, если есть запятая, кавычка, перенос строки или пробел по краям.
    static func field(_ text: String) -> String {
        let needsQuotes = text.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
            || text.first == " " || text.last == " "
        return needsQuotes ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }
}
