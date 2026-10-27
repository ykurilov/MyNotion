import PhoneShell
import SwiftUI

/// Строка состояния синхронизации внизу главного экрана — тихая, как значок внизу панели на Mac; касание — настройки.
struct SyncStatusBar: View {
    let badge: PhoneSyncBadge
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: badge.symbol)
                Text(badge.kind == .ready ? badge.lastSyncedTextNow : badge.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(badge.kind == .error ? PhoneTheme.destructive : PhoneTheme.textSecondary)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .accessibilityIdentifier("sync-status")
        .accessibilityLabel(badge.title)
        .accessibilityValue(badge.detail)
    }
}

extension PhoneSyncBadge {
    /// Подпись обновляется раз в полминуты, пока экран открыт.
    var lastSyncedTextNow: String { lastSyncedText(now: Date()) }
}
