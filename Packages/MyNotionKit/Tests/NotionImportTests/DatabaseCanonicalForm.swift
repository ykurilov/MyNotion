import Foundation
import NotesCore
import Testing
@testable import MarkdownExport
@testable import NotionImport

/// Базы без id для круговых проверок (SC-310): каждый id заменён названием того, на что он указывает, — у исходной
/// и у импортированной или возвращённой базы одинаково. Строки — схема, варианты, виды, ручной порядок, строки
/// со значениями, связями и телом.
/// - `editTimes`: даты создания и правки строк. Правка ячеек ставит строке новое «Изменено», поэтому проверки
///   «сменить тип → ⌘Z» и «удалить → вернуть» сравнивают без них.
/// - `computed`: итоги формул и сводок.
/// Удалённые варианты и пустые ячейки — следы для синхронизации, пользователь их не видит: в отпечаток не входят.
func canonicalDatabases(_ databaseIds: [UUID], in store: NotesStore, editTimes: Bool = true, computed: Bool = false) throws -> [String] {
    let snapshots = try databaseIds.map { try #require(try DatabaseExportSnapshot.read($0, from: store)) }
    var labels: [String: String] = [:]
    for snapshot in snapshots {
        let base = snapshot.title
        labels[snapshot.schema.pageId.databaseText] = "база:\(base)"
        for property in snapshot.properties { labels[property.id.databaseText] = "свойство:\(base)/\(property.name)" }
        let names = Dictionary(uniqueKeysWithValues: snapshot.properties.map { ($0.id, $0.name) })
        for option in snapshot.options { labels[option.id.databaseText] = "вариант:\(names[option.propertyId] ?? "?")/\(option.name)" }
        for view in snapshot.views { labels[view.id.databaseText] = "вид:\(base)/\(view.name)" }
        for (index, row) in snapshot.rows.enumerated() { labels[row.id.databaseText] = "строка:\(base)/\(index)" }
        for (index, row) in snapshot.templates.enumerated() { labels[row.id.databaseText] = "шаблон:\(base)/\(index)" }
    }
    func label(_ value: JSONValue?) -> String {
        guard let value else { return "∅" }
        func walk(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let text):
                if let mapped = labels[text] { return .string(mapped) }
                return .string(DatabaseSchemaImport.replacingIds(in: text, labels))
            case .array(let items): return .array(items.map(walk))
            case .object(let object): return .object(object.mapValues(walk))
            default: return value
            }
        }
        return walk(value).jsonText
    }
    var lines: [String] = []
    for snapshot in snapshots {
        let names = Dictionary(uniqueKeysWithValues: snapshot.properties.map { ($0.id, $0.name) })
        lines.append("база \(snapshot.title) встроенная=\(snapshot.schema.isInline) шаблон=\(label(snapshot.schema.defaultTemplateId.map { .string($0.databaseText) }))")
        for property in snapshot.properties {
            lines.append("свойство \(property.name) \(property.kind.rawValue) \(label(property.config)) удалено=\(property.deletedAt.map { "\($0.timeIntervalSince1970)" } ?? "нет")")
        }
        for option in snapshot.options where option.deletedAt == nil { lines.append("вариант \(names[option.propertyId] ?? "?")/\(option.name) \(option.color) \(option.statusGroup?.rawValue ?? "")") }
        for view in snapshot.views {
            lines.append("вид \(view.name) \(view.type) \(label(view.filter)) \(label(view.sorts)) \(label(view.columns)) \(label(view.group)) \(label(view.layoutOptions))")
        }
        for order in snapshot.rowOrders { lines.append("порядок \(label(.string(order.viewId.databaseText))) \(label(.string(order.rowId.databaseText)))") }
        for row in snapshot.rows + snapshot.templates {
            var line = "строка «\(row.title)» шаблон=\(row.isTemplate)"
            if editTimes { line += " \(row.createdAt.timeIntervalSince1970) \(row.updatedAt.timeIntervalSince1970)" }
            for (propertyId, value) in (snapshot.cells[row.id] ?? [:]).sorted(by: { names[$0.key] ?? "" < names[$1.key] ?? "" }) {
                guard let value else { continue }
                line += " | \(names[propertyId] ?? "?")=\(label(value))"
            }
            for (propertyId, targets) in (snapshot.relations[row.id] ?? [:]).sorted(by: { names[$0.key] ?? "" < names[$1.key] ?? "" }) {
                var labels = targets.map { label(.string($0.databaseText)) }
                // Ответная сторона пары своего порядка не хранит: связи идут по ключам другой стороны, а при равных
                // ключах — по id связи, который при импорте новый. Сторона хранения сравнивается по порядку.
                let paired = snapshot.properties.first { $0.id == propertyId }?.config["pairedPropertyId"]?.string
                    .flatMap(UUID.init(uuidString:))
                if let paired, paired < propertyId { labels.sort() }
                line += " | \(names[propertyId] ?? "?")→\(labels.joined(separator: ","))"
            }
            if computed {
                for (propertyId, value) in (snapshot.computed[row.id] ?? [:]).sorted(by: { names[$0.key] ?? "" < names[$1.key] ?? "" }) {
                    line += " | \(names[propertyId] ?? "?")≔\(label(value))"
                }
            }
            let body = try #require(try store.pageContent(row.id)).blocks.map { "\($0.kind.rawValue):\($0.text.string)" }
            lines.append(line + " | тело " + body.joined(separator: " / "))
        }
    }
    return lines
}

/// Сверить отпечатки: строки, которые пропали, и строки, которые появились (не построчно — одна лишняя строка сдвинула
/// бы все следующие). Порядок строк проверяется отдельно.
func expectSameDatabases(_ original: [String], _ current: [String], _ circle: String, sourceLocation: SourceLocation = #_sourceLocation) {
    guard original != current else { return }
    var left = Dictionary(original.map { ($0, 1) }, uniquingKeysWith: +)
    var added: [String] = []
    for line in current {
        if let count = left[line], count > 0 { left[line] = count - 1 } else { added.append(line) }
    }
    let lost = original.filter { line in
        guard let count = left[line], count > 0 else { return false }
        left[line] = count - 1
        return true
    }
    if lost.isEmpty && added.isEmpty {
        Issue.record("\(circle): те же строки в другом порядке", sourceLocation: sourceLocation)
        return
    }
    for index in 0..<min(5, max(lost.count, added.count)) {
        let before = index < lost.count ? lost[index] : "—"
        let after = index < added.count ? added[index] : "—"
        Issue.record("\(circle)\nбыло:  \(before)\nстало: \(after)", sourceLocation: sourceLocation)
    }
    if lost.count > 5 || added.count > 5 {
        Issue.record("\(circle): всего пропало строк \(lost.count), появилось \(added.count)", sourceLocation: sourceLocation)
    }
}
