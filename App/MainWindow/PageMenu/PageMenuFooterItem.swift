import Foundation
import PageEditor

extension PageMenuItems {
    /// Подвал серым: «Изменено: сегодня в 18:25, N слов».
    static var footer: PageMenuItem? {
        PageMenuItem(slot: .footer, title: { PageMenuFooter.text(for: $0) }, kind: .footer)
    }
}
