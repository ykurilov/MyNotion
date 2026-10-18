import AppKit
import SwiftUI
import VisualStyle

/// Что показать в значке синхронизации (FR-022). Панель о самом модуле синхронизации ничего не знает.
public struct SyncBadgeState: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Всё отправлено.
        case ready
        /// Идёт отправка.
        case sending
        /// Что-то мешает синхронизации.
        case error
    }

    public var kind: Kind
    /// Подробности словами: что случилось и что будет дальше.
    public var detail: String
    public var lastSyncedAt: Date?

    public init(kind: Kind, detail: String, lastSyncedAt: Date? = nil) {
        self.kind = kind
        self.detail = detail
        self.lastSyncedAt = lastSyncedAt
    }

    public var title: String {
        switch kind {
        case .ready: "Синхронизировано"
        case .sending: "Отправка…"
        case .error: "Ошибка синхронизации"
        }
    }

    var symbol: String {
        switch kind {
        case .ready: "checkmark.icloud"
        case .sending: "arrow.triangle.2.circlepath.icloud"
        case .error: "exclamationmark.icloud"
        }
    }
}

/// Строка внизу боковой панели: значок и состояние синхронизации; щелчок — подробности (contracts/editor-interactions.md).
public struct SyncStatusBadge: View {
    let state: SyncBadgeState
    let openSettings: () -> Void
    @State private var details = SyncDetailsCard()

    public init(state: SyncBadgeState, openSettings: @escaping () -> Void) {
        self.state = state
        self.openSettings = openSettings
    }

    public var body: some View {
        Button { details.toggle(content: detailsView) } label: {
            HStack(spacing: Metrics.Sidebar.rowIconSpacing) {
                Image(systemName: state.symbol)
                    .font(.system(size: Metrics.Sidebar.rowEmojiFontSize - 1, weight: .regular))
                    .foregroundStyle(Color(nsColor: state.kind == .error ? Palette.destructiveText : Palette.sidebarIcon))
                    .frame(width: Metrics.Sidebar.rowIconSize, height: Metrics.Sidebar.rowIconSize)
                Text(state.title)
                    .font(Font(Typography.sidebarRow.font))
                    .foregroundStyle(Color(nsColor: state.kind == .error ? Palette.destructiveText : Palette.sidebarText))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.Sidebar.rowHorizontalPadding)
            .padding(.vertical, Metrics.Sidebar.rowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: Metrics.Sidebar.rowHeight, maxHeight: Metrics.Sidebar.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
        .accessibilityIdentifier("sidebar-sync-status")
        .accessibilityLabel(state.title)
        .accessibilityValue(state.detail)
        .background(DetailsAnchor(card: details))
        .onDisappear { details.card.close() }
    }

    private var detailsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(state.title, systemImage: state.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(nsColor: state.kind == .error ? Palette.destructiveText : Palette.textPrimary))
            Text(state.detail)
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: Palette.textPrimary))
                .fixedSize(horizontal: false, vertical: true)
            if let lastSyncedAt = state.lastSyncedAt {
                Text("Последний раз всё сошлось: \(lastSyncedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
            }
            Button("Настройки синхронизации…") { [details, openSettings] in
                details.card.close()
                openSettings()
            }
            .padding(.top, 4)
            .accessibilityIdentifier("sync-open-settings")
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-details")
    }
}

/// Карточка подробностей у строки значка (тот же вид, что окно корзины).
@MainActor
final class SyncDetailsCard {
    let card = PopupCard()
    weak var anchorView: NSView?

    func toggle(content: some View) {
        if card.isShown { return card.close() }
        guard let anchorView else { return }
        let hosting = NSHostingView(rootView: content)
        card.show(hosting, size: hosting.fittingSize, besides: anchorView)
    }
}

private struct DetailsAnchor: NSViewRepresentable {
    let card: SyncDetailsCard

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        card.anchorView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        card.anchorView = view
    }
}
