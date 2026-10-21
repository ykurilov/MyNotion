import Foundation

/// Сравнимый текст ячейки (data-model.md, `sortText`, `searchText`): нижний регистр, без диакритики, «ё» как «е».
/// «й» остаётся буквой: иначе «Йогурт» встал бы среди «И». Побайтовый порядок такого текста — порядок алфавита
/// для кириллицы и латиницы, поэтому SQLite сортирует его по индексу, без своей функции сравнения.
public enum SortableText {
    public static func make(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text.lowercased() {
            switch character {
            case "й": result.append("й")
            case "ё": result.append("е")
            default:
                if character.isASCII { result.append(character) } else {
                    result += String(character).folding(options: .diacriticInsensitive, locale: nil)
                }
            }
        }
        return result
    }
}
