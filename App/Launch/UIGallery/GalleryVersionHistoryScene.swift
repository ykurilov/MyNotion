import AppKit
import NotesCore
import PageVersions
import UIGallery

/// История версий в галерее (US6): страница «Замер: история версий» с 200 версиями (`PageVersionsSample`).
@MainActor
enum GalleryVersionHistoryScene {
    static let deviceName = "MacBook Pro Юрия"

    static func show(_ kind: GalleryVersionHistory, model: MainWindowModel) async -> String? {
        guard let pageId = try? PageVersionsSample.ensure(in: model.store, versions: model.versions.versions, deviceName: deviceName) else {
            return "образец истории не записался"
        }
        model.library.reloadTree()
        model.select(pageId)
        try? await Task.sleep(for: .milliseconds(300))
        model.showVersionHistory(pageId)
        guard let history = model.versionHistory, history.rows.count > 3 else { return "история не открылась" }
        // Прошлая версия: с подсветкой отличий от текущей.
        history.select(history.rows[3].id)
        switch kind {
        case .list: break
        case .grouped: history.grouping = .quarterHour
        case .details: history.isExpanded = true
        case .restoreDialog: history.isRestoreDialogShown = true
        case .restoredBanner:
            model.restoreVersion(history.rows[3].id, ofPage: pageId)
            try? await Task.sleep(for: .milliseconds(300))
            guard model.showsRestoredBanner else { return "полосы нет" }
        }
        try? await Task.sleep(for: .milliseconds(500))
        return nil
    }

    static func tearDown(model: MainWindowModel) {
        model.closeVersionHistory()
        model.restoredVersionPageId = nil
    }
}
