import PageEditor
import SwiftUI
import VisualStyle

/// Короткая плашка внизу окна после «Копировать ссылку», сама уходит через полторы секунды.
struct LinkCopiedToast: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
            Text(PageLinkCopy.confirmation).font(.system(size: 13))
        }
        .foregroundStyle(Color(nsColor: Palette.textPrimary))
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Palette.pageBackground)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: Palette.dividerLine), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("link-copied-toast")
    }
}
