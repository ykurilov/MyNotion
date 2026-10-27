import NotesCore
import PhonePageEditor
import PhoneShell
import SwiftUI
import UIKit

/// Страница — редактор `PhonePageViewController` на общих открытых страницах приложения (`library.openDocuments`).
/// Правки с других устройств доходят до него через `OpenDocuments` (это делает синхронизация), «+» подстраницы —
/// тоже (`PageBrowser`); при уходе в фон и закрытии экран сохраняется сам. Касание подстраницы — `openPage`.
struct PageScreen: View {
    let pageId: UUID
    let library: PhoneLibrary
    let openPage: (UUID) -> Void

    var body: some View {
        PageEditor(pageId: pageId, openDocuments: library.openDocuments, openPage: openPage)
            .ignoresSafeArea(.keyboard)
            .id(pageId)
    }
}

private struct PageEditor: UIViewControllerRepresentable {
    let pageId: UUID
    let openDocuments: OpenDocuments
    let openPage: (UUID) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        do {
            return try PhonePageViewController(pageId: pageId, openDocuments: openDocuments, onOpenPage: openPage)
        } catch {
            return UIHostingController(rootView: ContentUnavailableView(
                "Страница не открылась", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription)))
        }
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
