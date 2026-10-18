import Foundation

/// Таблица CSV из выгрузки Notion (RFC 4180): кавычки, запятые и переносы внутри значения, метка BOM в начале.
enum NotionCSV {
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var characters = text.drop { $0 == "\u{FEFF}" }.makeIterator()
        var pending: Character?
        while let character = pending ?? characters.next() {
            pending = nil
            if isQuoted {
                if character == "\"" {
                    let next = characters.next()
                    if next == "\"" { field.append("\"") } else { isQuoted = false; pending = next }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty: isQuoted = true
            case ",":
                row.append(field)
                field = ""
            case "\n", "\r\n", "\r":
                row.append(field)
                field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            default: field.append(character)
            }
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }

    /// Строка таблицы — абзац «Колонка: значение» через перенос строки; пустые значения пропущены (contracts/files-import-export.md).
    static func paragraphs(_ text: String) -> [String] {
        let all = rows(text)
        guard let header = all.first else { return [] }
        return all.dropFirst().compactMap { row in
            let pairs = zip(header, row).compactMap { column, value -> String? in
                let value = value.trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : "\(column.trimmingCharacters(in: .whitespaces)): \(value)"
            }
            return pairs.isEmpty ? nil : pairs.joined(separator: "\n")
        }
    }
}
