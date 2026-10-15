import SwiftUI
import VisualStyle

/// Жёлтая полоса над страницей, пока запись не удаётся (FR-015, contracts/editor-interactions.md, «Сообщения»).
/// Правки остаются в памяти, автосохранение повторяет запись; полоса исчезает после удачной записи.
public struct SaveStatusBanner: View {
    let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var body: some View {
        HStack(spacing: 0) {
            Text("Изменения не сохранены — \(reason). Повторяем…")
                .font(Font(Typography.breadcrumb.font))
                .foregroundStyle(Color(nsColor: Palette.textPrimary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.SaveErrorBanner.horizontalPadding)
        .frame(height: Metrics.SaveErrorBanner.height)
        .background(Color(nsColor: Palette.saveErrorBannerBackground))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("save-error-banner")
    }
}
