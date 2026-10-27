import PhoneShell
import SwiftUI

/// Верхняя полоса страницы: «назад» (и жестом), путь к странице и «+» новой подстраницы. Саму страницу рисует `PageScreen`.
struct PageContainer: View {
    let pageId: UUID
    let library: PhoneLibrary
    let openPage: (UUID) -> Void

    var body: some View {
        PageScreen(pageId: pageId, library: library, openPage: openPage)
            .navigationTitle(parentPath)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: addSubpage) { Image(systemName: "plus") }
                        .accessibilityLabel("Новая подстраница")
                        .accessibilityIdentifier("new-subpage")
                }
            }
    }

    /// Над страницей — где она лежит, как хлебные крошки в Notion.
    private var parentPath: String {
        _ = library.browser.revision
        return library.browser.ancestors(of: pageId).map(\.displayTitle).joined(separator: " / ")
    }

    private func addSubpage() {
        guard let page = try? library.browser.createPage(in: pageId) else { return }
        openPage(page.id)
    }
}
