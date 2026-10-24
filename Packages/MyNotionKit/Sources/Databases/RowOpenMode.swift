import Foundation
import NotesCore

/// Как открывается строка (data-model.md, `layoutOptions.openRowsIn`; Notion 7.39 «Open pages in»): сбоку — по
/// умолчанию у таблицы, по центру, на всю страницу.
public enum RowOpenMode: String, Sendable, Hashable, CaseIterable {
    case sidePeek, centerPeek, fullPage

    /// Способ вида; неизвестное значение — сбоку.
    public init(view: DatabaseView) {
        self = view.layoutOptions["openRowsIn"]?.string.flatMap(RowOpenMode.init(rawValue:)) ?? .sidePeek
    }
}
