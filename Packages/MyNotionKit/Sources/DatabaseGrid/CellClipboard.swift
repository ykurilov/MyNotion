import AppKit
import Databases
import NotesCore

/// Что вставить: значения по ячейкам и сколько строк добавить в конец (вставка за последнюю строку).
public struct CellPastePlan: Sendable, Hashable {
    public var writes: [CellWrite]
    public var appendedRows: Int
}

/// Буфер ячеек (contracts/database-ui.md, «Ячейки и клавиши»): ⌘C — текст с табуляциями и переводами строк и простая
/// таблица HTML (её понимает Numbers), ⌘V — блок с выбранной ячейки, новые строки — если не хватило, лишние колонки
/// отбрасываются (Notion колонок не создаёт), ⌫ — пусто.
public enum CellClipboard {
    // MARK: Копирование

    /// Текст с табуляциями; ячейка с табуляцией, переводом строки или кавычкой — в кавычках, кавычки удваиваются.
    public static func tsv(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { cell in
                guard cell.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" }) else { return cell }
                return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// Простая таблица HTML.
    public static func html(_ rows: [[String]]) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
        }
        let body = rows.map { row in "<tr>" + row.map { "<td>\(escape($0))</td>" }.joined() + "</tr>" }.joined()
        return "<meta charset=\"utf-8\"><table>\(body)</table>"
    }

    /// Положить ячейки в буфер обмена: текст и HTML.
    @MainActor
    public static func write(_ rows: [[String]], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .html], owner: nil)
        pasteboard.setString(tsv(rows), forType: .string)
        pasteboard.setString(html(rows), forType: .html)
    }

    /// Текст ячеек из буфера обмена.
    @MainActor
    public static func read(from pasteboard: NSPasteboard = .general) -> [[String]] {
        parse(pasteboard.string(forType: .string) ?? "")
    }

    // MARK: Вставка

    /// Разбор текста с табуляциями (Numbers, Excel, Notion): кавычки, переводы строк внутри кавычек, `\r\n`.
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var atFieldStart = true
        var characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))[...]
        while let character = characters.popFirst() {
            if quoted {
                if character == "\"" {
                    if characters.first == "\"" { field.append("\""); characters.removeFirst() } else { quoted = false }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where atFieldStart:
                quoted = true
                atFieldStart = false
            case "\t":
                row.append(field)
                field = ""
                atFieldStart = true
            case "\n", "\r":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                atFieldStart = true
            default:
                field.append(character)
                atFieldStart = false
            }
        }
        if !field.isEmpty || !row.isEmpty || !atFieldStart { row.append(field); rows.append(row) }
        return rows
    }

    /// План вставки блока `values` с левой верхней ячейки выделения; одно значение в прямоугольник — во все его ячейки.
    /// `contexts` — видимые колонки по порядку, `rowIds` — строки вида.
    public static func pastePlan(_ values: [[String]], at selection: CellSelection, rowIds: [UUID], contexts: [PropertyContext]) -> CellPastePlan {
        guard !values.isEmpty else { return CellPastePlan(writes: [], appendedRows: 0) }
        var writes: [CellWrite] = []
        var appended = 0
        if values.count == 1, values[0].count == 1, !selection.isSingleCell {
            for row in selection.rows where row < rowIds.count {
                for column in selection.columns where column < contexts.count {
                    if let write = write(values[0][0], row: .existing(rowIds[row]), context: contexts[column]) { writes.append(write) }
                }
            }
            return CellPastePlan(writes: writes, appendedRows: 0)
        }
        let start = selection.topLeft
        for (offset, line) in values.enumerated() {
            let row = start.row + offset
            let target: CellRowTarget
            if row < rowIds.count {
                target = .existing(rowIds[row])
            } else {
                target = .appended(row - rowIds.count)
                appended = max(appended, row - rowIds.count + 1)
            }
            for (columnOffset, text) in line.enumerated() {
                let column = start.column + columnOffset
                guard column < contexts.count else { break }
                if let write = write(text, row: target, context: contexts[column]) { writes.append(write) }
            }
        }
        return CellPastePlan(writes: writes, appendedRows: appended)
    }

    /// ⌫: пустые значения выбранных ячеек; у названия — пустое название.
    public static func eraseWrites(_ selection: CellSelection, rowIds: [UUID], contexts: [PropertyContext]) -> [CellWrite] {
        selection.rows.filter { $0 < rowIds.count }.flatMap { row in
            selection.columns.filter { $0 < contexts.count }.compactMap { column -> CellWrite? in
                let property = contexts[column].property
                guard property.kind == .title || CellKind.for(property.kind).editing != .none else { return nil }
                return CellWrite(row: .existing(rowIds[row]), propertyId: property.id, value: property.kind == .title ? .string("") : nil)
            }
        }
    }

    /// Значение ячейки из текста по типу колонки. Варианты — только уже существующие (новые варианты при вставке
    /// создаёт US2); не найденное и не правящееся — пропускается.
    static func write(_ text: String, row: CellRowTarget, context: PropertyContext) -> CellWrite? {
        let property = context.property
        if property.kind == .title { return CellWrite(row: row, propertyId: property.id, value: .string(text)) }
        guard property.kind.storesCells, CellKind.for(property.kind).editing != .none else { return nil }
        switch PropertyTypes.type(for: property.kind).parseCSV(text, in: context) {
        case .value(let value):
            return CellWrite(row: row, propertyId: property.id, value: value)
        case .options(let names):
            let ids = names.compactMap { context.option(named: $0) }.map { JSONValue.string($0.id.databaseText) }
            guard !ids.isEmpty else { return nil }
            return CellWrite(row: row, propertyId: property.id, value: property.kind == .multiSelect ? .array(ids) : ids[0])
        }
    }
}
