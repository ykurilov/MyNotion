import AppKit
import PageVersions
import PageEditor
import SwiftUI
import VisualStyle

/// «Восстановить» → окно «Что будет восстановлено» (≈ `notion-version-restore.png`): слева — что вернётся и
/// «Восстановить эту версию», справа — та же версия. Esc и «×» закрывают.
struct VersionRestoreDialogLayer: ViewModifier {
    @Bindable var history: VersionHistoryModel
    let linkedPages: [UUID: LinkedPage]
    let mentions: MentionSettings
    let headerAddons: [PageHeaderAddonFactory]
    let restore: (UUID) -> Void

    func body(content: Content) -> some View {
        content.overlay {
            if history.isRestoreDialogShown, let version = history.selected, let preview = history.preview {
                ZStack {
                    Color(nsColor: Palette.modalBackdrop)
                        .contentShape(Rectangle())
                        .onTapGesture { history.isRestoreDialogShown = false }
                    HStack(spacing: 0) {
                        summary(time: VersionTimeText.inSentence(for: version.createdAt), versionId: version.id)
                            .frame(width: 280)
                        VersionPreviewView(document: preview.document, highlightedBlockIds: [], linkedPages: linkedPages,
                                           mentions: mentions, headerAddons: headerAddons)
                            .id("restore-\(preview.versionId)")
                    }
                    .background(Color(nsColor: Palette.popupMenuBackground), in: RoundedRectangle(cornerRadius: 10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: Palette.border)))
                    .overlay(alignment: .topTrailing) {
                        Button { history.isRestoreDialogShown = false } label: {
                            Image(systemName: "xmark").font(.system(size: 13)).frame(width: 28, height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Закрыть")
                        .padding(8)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 16)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("version-restore-dialog")
            }
        }
    }

    private func summary(time: String, versionId: UUID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            (Text("Восстановить ").foregroundStyle(Color(nsColor: Palette.textSecondary)) + Text(verbatim: history.pageTitle).bold()
                + Text("\nк ").foregroundStyle(Color(nsColor: Palette.textSecondary)) + Text(verbatim: time).bold())
                .font(.system(size: 14))
                .lineSpacing(2)
            Text("Что будет восстановлено")
                .font(.system(size: 13, weight: .medium))
                .padding(.top, 28)
                .padding(.bottom, 10)
            item("doc.text", "Всё содержимое страницы", "Текст, блоки и всё остальное на этой странице.")
            item("arrow.uturn.left", "Перенесённое", "Блоки, унесённые на другие страницы, вернутся сюда.")
            item("list.bullet", "Свойства страницы", "Иконка, обложка и вид страницы.")
            Spacer()
            Button { restore(versionId) } label: {
                Text("Восстановить эту версию")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(Color(nsColor: Palette.primaryButtonFill), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("version-restore-confirm")
            Text("Другие версии не удаляются, восстановить можно снова")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .foregroundStyle(Color(nsColor: Palette.textPrimary))
        .padding(20)
    }

    private func item(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 12)).foregroundStyle(Color(nsColor: Palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 12)
    }
}

/// Полоса над страницей после восстановления, как у Notion 7.39 (`notion-version-restored.png`): высота 44, текст 14,
/// в тёмной теме — фон 0x233850 и текст 0x387DC9.
struct VersionRestoredBanner: View {
    let close: () -> Void

    static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x23 / 255, green: 0x38 / 255, blue: 0x50 / 255, alpha: 1) : NSColor(srgbRed: 0.91, green: 0.95, blue: 0.99, alpha: 1)
    }
    static let text = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x38 / 255, green: 0x7D / 255, blue: 0xC9 / 255, alpha: 1) : NSColor(srgbRed: 0.14, green: 0.51, blue: 0.89, alpha: 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
            Text("Страница восстановлена").font(.system(size: 14))
            Spacer()
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 11)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть полосу")
        }
        .foregroundStyle(Color(nsColor: Self.text))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: Self.background))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("version-restored-banner")
    }
}
