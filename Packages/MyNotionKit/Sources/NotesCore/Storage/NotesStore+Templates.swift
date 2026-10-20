import Foundation
import GRDB

/// Раздел «Шаблоны» (research R12): страницы с отметкой `isTemplate`, не в корзине (сами и вместе с предком),
/// по порядку среди соседей. Подстраницы шаблона в список не входят — они лежат под своим шаблоном.
extension NotesStore {
    public func templatePages() throws -> [Page] {
        try database.dbWriter.read { db in
            let hidden = try Self.trashedPageIds(db)
            return try Row.fetchAll(db, sql: "SELECT * FROM page WHERE isTemplate = 1").map(Page.init(row:))
                .filter { !hidden.contains($0.id) }
                .sorted(by: PageTreeSnapshot.siblingOrder)
        }
    }
}
