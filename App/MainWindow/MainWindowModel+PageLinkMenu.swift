import Foundation
import Navigation
import PageEditor

/// Пункты меню ссылки на страницу, которых нет у меню строки панели.
extension MainWindowModel {
    /// «Открыть в новом окне»: новое окно с этой страницей, как `mynotion open --newWindow`.
    func openInNewWindow(_ pageId: UUID) {
        guard let openNewWindow = library.openNewWindow else { return }
        library.pageForNextNewWindow = pageId
        openNewWindow()
    }

    /// «Спросить ИИ»: панель агента прикладывает к сообщению открытую страницу, поэтому страница по ссылке
    /// открывается здесь же, а панель — рядом с ней.
    func askAI(about pageId: UUID) {
        if openPageId != pageId { open(PageOpenRequest(pageId: pageId)) }
        aiChat.isOpen = true
    }

    /// Подвал меню ссылки: «Изменено: …, N слов» страницы по ссылке.
    func pageLinkFooter(_ pageId: UUID) -> String? {
        guard let content = try? store.pageContent(pageId) else { return nil }
        let words = PageMenuFooter.wordCount(of: [content.page.title] + content.blocks.map(\.text.string))
        return PageMenuFooter.text(for: PageMenuContext(page: content.page, wordCount: words))
    }
}
