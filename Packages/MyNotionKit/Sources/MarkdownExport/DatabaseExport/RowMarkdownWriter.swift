import Databases
import Foundation
import NotesCore

/// Markdown строки базы (как у Notion): «# Название», пустая строка, непустые «Свойство: значение» в порядке колонок CSV,
/// пустая строка, тело по правилам 001–003. Импорт отрезает строки свойств по названиям колонок.
enum RowMarkdownWriter {
    /// `relationPath` — путь файла строки-цели от файла строки (кодируется, как ссылки страниц).
    static func propertyLines(of row: Page, in snapshot: DatabaseExportSnapshot, values: DatabaseValueText,
                              relationPath: (UUID) -> String?) -> [String] {
        func relation(_ id: UUID) -> String {
            let title = values.title(ofTarget: id)
            return relationPath(id).map { "\(title) (\(InlineMarkdown.encodedPath($0)))" } ?? title
        }
        return snapshot.columns.filter { $0.kind != .title }.compactMap { property in
            let text = values.text(property, of: row, relation: relation)
            return text.isEmpty ? nil : "\(property.name): \(text)"
        }
    }
}
