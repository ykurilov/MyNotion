import AppKit
import NotesCore

/// Добавка шапки страницы от хозяина редактора (plan.md, Structure Decision: редактор знает обложку через протокол,
/// который передаёт `App/`). Ставит свои виды в места шапки (`setCover`, `header.addButton`, `setUnderTitle`)
/// и обновляет их, когда страница сменилась (обложка, вид, правка с другого Mac).
@MainActor
public protocol PageHeaderAddon: AnyObject {
    /// Редактор страницы создан: поставить свои виды.
    func install(in textView: PageTextView)
    /// Поля страницы в документе сменились.
    func pageDidChange(_ page: Page, in textView: PageTextView)
}

/// Создать добавку для документа открытой страницы: одна на редактор.
public typealias PageHeaderAddonFactory = @MainActor (PageDocument) -> any PageHeaderAddon

extension PageTextView {
    /// Поставить добавки шапки; повторный вызов не нужен — редактор держит их до конца.
    public func installHeaderAddons(_ addons: [any PageHeaderAddon]) {
        headerAddons += addons
        for addon in addons { addon.install(in: self) }
    }
}
