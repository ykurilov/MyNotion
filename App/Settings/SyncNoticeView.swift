import SwiftUI
import Sync
import VisualStyle

/// Карточка внизу окна: что случилось при синхронизации — страница вернулась из корзины или из стёртых (T082).
struct SyncNoticeView: View {
    let controller: SyncController

    var body: some View {
        if let notice = controller.notices.first {
            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
                Text(notice.message)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sync-notice-text")
                if controller.notices.count > 1 {
                    Text("ещё \(controller.notices.count - 1)")
                        .foregroundStyle(Color(nsColor: Palette.textSecondary))
                }
                Button("Понятно") { controller.dismissNotice() }
                    .accessibilityIdentifier("sync-notice-close")
            }
            .font(.system(size: 14))
            .foregroundStyle(Color(nsColor: Palette.textPrimary))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 560)
            .background(Color(nsColor: Palette.popupMenuBackground), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: Palette.border)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.bottom, 20)
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sync-notice")
        }
    }
}
