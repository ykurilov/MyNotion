import Foundation
import NotesCore

/// Имена файлов и папок выгрузки: у каждой страницы своё имя среди соседей, одинаковое для файла и папки подстраниц.
struct ExportFileNames {
    /// Самое длинное имя без ` (N)` и `.md`; весь файл — не больше 255 байт (предел имени на диске Mac).
    static let maxBaseBytes = 200
    static let emptyTitleName = Page.untitledTitle

    /// Имя страницы без расширения: `/` и `:` заменены на `-`, управляющие знаки убраны, точка в начале
    /// не прячет файл, длина в пределах. Название пустое — «Без названия».
    static func baseName(forTitle title: String) -> String {
        var name = ""
        for scalar in title.unicodeScalars {
            switch scalar {
            case "/", ":": name += "-"
            case "\n", "\r", "\t": name += " "
            default:
                if scalar.value >= 0x20, scalar.value != 0x7F { name.unicodeScalars.append(scalar) }
            }
        }
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        while name.utf8.count > maxBaseBytes { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? emptyTitleName : name
    }

    /// Имена соседей по порядку. Одинаковые (без учёта регистра: диск Mac его не различает) получают ` (2)`, ` (3)`.
    static func uniqueNames(forTitles titles: [String]) -> [String] {
        var used: Set<String> = []
        return titles.map { title in
            let base = baseName(forTitle: title)
            var candidate = base
            var number = 2
            while used.contains(key(candidate)) {
                candidate = "\(base) (\(number))"
                number += 1
            }
            used.insert(key(candidate))
            return candidate
        }
    }

    private static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
