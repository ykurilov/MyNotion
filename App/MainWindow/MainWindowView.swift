import SwiftUI

/// Каркас окна: боковая панель со страницами слева, открытая страница справа.
struct MainWindowView: View {
    var body: some View {
        NavigationSplitView {
            List {}
                .navigationSplitViewColumnWidth(min: 200, ideal: 270)
        } detail: {
            Color.clear
        }
    }
}
