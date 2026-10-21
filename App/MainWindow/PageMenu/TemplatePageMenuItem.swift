import Foundation
import PageEditor

extension PageMenuItems {
    /// «Сделать шаблоном / Перестать быть шаблоном» (US7): шаблон уходит в раздел «Шаблоны», обратно — в корень «Страниц».
    static func template(_ model: MainWindowModel, _ pageId: UUID) -> PageMenuItem? {
        PageMenuItem(slot: .template, title: { $0.page.isTemplate ? "Перестать быть шаблоном" : "Сделать шаблоном" },
                     kind: .action({ _ in model.toggleTemplate(pageId) }))
    }
}
