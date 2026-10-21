import NotesCore
import PageEditor
import SwiftUI
import VisualStyle

/// Место окна истории: под строкой вкладок на всю ширину окна, поверх панели и страницы (как Notion 7.39).
struct VersionHistoryOverlay: View {
    let model: MainWindowModel
    let mentions: MentionSettings

    var body: some View {
        if let history = model.versionHistory {
            VersionHistoryView(history: history, linkedPages: model.linkedPages, mentions: mentions,
                               headerAddons: [VersionCoverAddon.factory(model)],
                               close: { model.closeVersionHistory() },
                               restore: { model.restoreVersion($0, ofPage: history.pageId) })
                .padding(.top, Metrics.Window.titleBarHeight)
        }
    }
}
