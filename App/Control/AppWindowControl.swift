import AppKit
import ControlCommands
import Foundation

/// Окна и вкладки для команд. Пока только чтение: `current` в указателе страницы и список окон. Открытие, вкладки
/// и «назад/вперёд» — этап 6 (по умолчанию `not_implemented` из `WindowControl`).
@MainActor
final class AppWindowControl: WindowControl {
    private unowned let library: PagesLibrary

    init(library: PagesLibrary) {
        self.library = library
    }

    var currentPageId: UUID? { library.activeWindow?.openPageId }

    func windows() -> [WindowInfo] {
        library.windowModels.enumerated().map { index, model in
            let pageId = model.openPageId
            let title = pageId.flatMap { library.tree.page($0)?.title } ?? ""
            return WindowInfo(index: index + 1, isFront: model === library.activeWindow,
                              tabs: [TabInfo(index: 1, pageId: pageId, title: title, isSelected: true)],
                              canGoBack: false, canGoForward: false, isBusy: model.window?.attachedSheet != nil)
        }
    }
}
