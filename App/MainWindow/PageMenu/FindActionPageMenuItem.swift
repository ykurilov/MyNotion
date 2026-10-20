import Foundation
import PageEditor

extension PageMenuItems {
    /// Поле «Найти действие…» сверху: сужает меню до пунктов с запросом.
    static var findAction: PageMenuItem? {
        PageMenuItem(slot: .findAction, title: { _ in "Найти действие…" }, kind: .search)
    }
}
