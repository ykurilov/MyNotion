import Databases
import Foundation
import Navigation

/// Открыть строку базы (US1, contracts/database-ui.md, «Страница строки»): сбоку, по центру или на всю страницу;
/// `mode == nil` — способом вида. Заготовка: пока строка всегда открывается на всю страницу — просмотр сбоку и по
/// центру делает T043.
extension MainWindowModel {
    func openRow(_ rowId: UUID, mode: RowOpenMode, inNewTab: Bool = false) {
        open(PageOpenRequest(pageId: rowId, inNewTab: inNewTab))
    }
}
