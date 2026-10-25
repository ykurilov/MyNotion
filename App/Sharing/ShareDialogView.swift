import AppKit
import PageSharing
import SwiftUI
import VisualStyle

/// «•••» → «Поделиться» (006): ссылка на страницу только для чтения. Карточкой поверх окна (`modalCard`).
struct ShareDialogView: View {
    @Bindable var controller: ShareController
    let pageId: UUID
    let pageTitle: String
    let openSyncSettings: () -> Void
    let close: () -> Void
    @State private var copied = false
    @State private var confirmsRotate = false

    private var share: PageShare? { controller.shares[pageId] }
    private var isEnabled: Bool { share?.enabled == true }
    private var isBusy: Bool { controller.busyPageId == pageId }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ModalCardTitle(text: pageTitle.isEmpty ? "Поделиться страницей" : "Поделиться «\(pageTitle)»")
            if controller.isAvailable { available } else { needsSync }
            if let error = controller.errorMessage {
                Text(error)
                    .foregroundStyle(Color(nsColor: Palette.destructiveText))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("share-error")
            }
            HStack {
                Spacer()
                Button("Готово", action: close)
                    .buttonStyle(ModalCardButtonStyle(isPrimary: true))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("share-done")
            }
        }
        .focusEffectDisabled()
        .task(id: pageId) { await controller.load(pageId) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share-dialog")
    }

    private var needsSync: some View {
        VStack(alignment: .leading, spacing: 10) {
            secondary("Ссылки работают через сервер синхронизации. Сначала подключите этот Mac в настройках синхронизации.")
            Button("Настройки синхронизации…", action: openSyncSettings)
                .buttonStyle(ModalCardButtonStyle())
                .accessibilityIdentifier("share-open-sync")
        }
    }

    private var available: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(get: { isEnabled }, set: { on in Task { await controller.setEnabled(on, pageId: pageId) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Доступ по ссылке")
                    secondary("Кто знает ссылку, увидит страницу в браузере без входа. Изменить её он не сможет.")
                }
            }
            .toggleStyle(.switch)
            .disabled(isBusy)
            .accessibilityIdentifier("share-toggle")

            if isEnabled, let share, let url = controller.url(of: share) {
                link(url)
                Toggle("Вместе с подстраницами", isOn: Binding(get: { share.includeSubpages }, set: { value in
                    Task { await controller.setEnabled(true, pageId: pageId, includeSubpages: value) }
                }))
                .toggleStyle(.checkbox)
                .disabled(isBusy)
                .accessibilityIdentifier("share-subpages")
                secondary(share.includeSubpages
                          ? "Подстраницы тоже открываются по ссылке. Ссылки на остальные страницы видны как «Нет доступа»."
                          : "Открывается только эта страница и её встроенные базы. Ссылки на подстраницы видны как «Нет доступа».")
                secondary("Правки появятся по ссылке сами, через несколько секунд. Выключите доступ — ссылка сразу перестанет "
                          + "открываться. Включите снова — ссылка будет та же.")
                HStack(spacing: 10) {
                    Button("Сменить ссылку") { confirmsRotate = true }
                        .buttonStyle(ModalCardButtonStyle())
                        .disabled(isBusy)
                        .accessibilityIdentifier("share-rotate")
                    secondary("Старая ссылка сразу перестанет открываться.")
                }
            } else if share != nil {
                secondary("Ссылка выключена и не открывается. Включите доступ — ссылка будет прежней.")
            }
            if isBusy { ProgressView().controlSize(.small) }
        }
        .confirmationDialog("Сменить ссылку?", isPresented: $confirmsRotate) {
            Button("Сменить ссылку", role: .destructive) { Task { await controller.rotate(pageId) } }
        } message: {
            Text("Старая ссылка сразу перестанет открываться. Новую нужно будет отправить заново.")
        }
    }

    private func link(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: url.absoluteString)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: Palette.border)))
                .accessibilityIdentifier("share-url")
            Button(copied ? "Скопировано" : "Скопировать") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(2)); copied = false }
            }
            .buttonStyle(ModalCardButtonStyle(isPrimary: true))
            .accessibilityIdentifier("share-copy")
        }
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Color(nsColor: Palette.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}
