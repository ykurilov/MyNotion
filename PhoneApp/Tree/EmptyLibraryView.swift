import SwiftUI

/// Пустой iPhone до подключения: как перенести записи с Mac, или начать без подключения.
struct EmptyLibraryView: View {
    let connect: () -> Void
    let startLocally: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(PhoneTheme.icon)
            Text("Ваши записи с Mac — на iPhone")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(PhoneTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Подключите iPhone кодом с Mac — и страницы появятся здесь. Правки на iPhone сами уйдут на ваши Mac.")
                .font(.system(size: 16))
                .foregroundStyle(PhoneTheme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button(action: connect) {
                Text("Подключить кодом с Mac").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(PhoneTheme.accent)
            .accessibilityIdentifier("empty-connect")
            Button("Начать без подключения", action: startLocally)
                .foregroundStyle(PhoneTheme.textSecondary)
                .padding(.bottom, 8)
                .accessibilityIdentifier("empty-start-locally")
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .accessibilityIdentifier("empty-library")
    }
}

/// Полоса над деревом, пока iPhone не подключён, а записи на нём уже есть.
struct ConnectBanner: View {
    let connect: () -> Void

    var body: some View {
        Button(action: connect) {
            HStack(spacing: 12) {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 22))
                    .foregroundStyle(PhoneTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Подключить к вашим Mac")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(PhoneTheme.textPrimary)
                    Text("Записи пока только на этом iPhone")
                        .font(.system(size: 14))
                        .foregroundStyle(PhoneTheme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(PhoneTheme.icon)
            }
            .padding(14)
            .background(PhoneTheme.groupedBackground, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("connect-banner")
    }
}
