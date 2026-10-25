import Foundation

/// Окно «Поделиться» открытой страницы (006).
extension MainWindowModel {
    var sharing: ShareController { library.sharing }

    /// Набранное — в базу до публикации: по ссылке сразу видно то, что на экране.
    func showShareDialog(_ pageId: UUID) {
        openDocuments.saveAll()
        sharing.errorMessage = nil
        sharePageId = pageId
    }
}
