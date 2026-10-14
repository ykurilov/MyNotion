import NotesCore
import SwiftUI
import VisualStyle

/// Каркас окна: боковая панель со страницами слева, открытая страница справа.
struct MainWindowView: View {
    let library: Result<NotesStore, any Error>
    let launchReportURL: URL?

    var body: some View {
        NavigationSplitView {
            List {}
                .navigationSplitViewColumnWidth(min: Metrics.Sidebar.minimumWidth, ideal: Metrics.Sidebar.defaultWidth)
        } detail: {
            pageArea
                .onAppear {
                    // Следующий оборот цикла событий — окно уже на экране и принимает ввод.
                    DispatchQueue.main.async { LaunchMilestones.editorReady(reportTo: launchReportURL) }
                }
        }
    }

    @ViewBuilder
    private var pageArea: some View {
        switch library {
        case .success:
            Color.clear
        case .failure(let error):
            Text("Не удалось открыть записи: \(error.localizedDescription)")
                .foregroundStyle(.secondary)
                .padding()
        }
    }
}
