import AppKit
import NotesCore

/// «Копировать ссылку» (значок цепочки в верхней полосе, «•••», меню строки панели, ⌘L): адрес `mynotion://page/<id>`
/// в буфер обмена. Щелчок по нему открывает страницу, команды `mynotion` принимают его вместо id.
@MainActor
public enum PageLinkCopy {
    public static let title = "Копировать ссылку"
    public static let confirmation = "Ссылка скопирована"

    public static func copy(_ pageId: UUID, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(PageAddress(pageId: pageId).text, forType: .string)
    }
}
