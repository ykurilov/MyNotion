import AppKit
import NotesCore
import PageEditor
import PageVersions
import SwiftUI
import VisualStyle

/// «История версий» на всё окно под строкой вкладок (≈ `notion-version-history.png`, `notion-version-details.png`):
/// слева ≈ 250 — список версий с группировкой или раскрытая версия; справа — строка времени с «Восстановить» и «×»,
/// под ней версия «только чтение» с подсветкой отличий. Esc и «×» закрывают.
struct VersionHistoryView: View {
    @Bindable var history: VersionHistoryModel
    /// Справочник страниц и упоминаний — как у открытой страницы.
    let linkedPages: [UUID: LinkedPage]
    let mentions: MentionSettings
    let headerAddons: [PageHeaderAddonFactory]
    let close: () -> Void
    let restore: (UUID) -> Void

    static let listWidth: CGFloat = 250

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if history.isExpanded, let selected = history.selected {
                    VersionDetailsPanel(history: history, version: selected)
                } else {
                    VersionListPanel(history: history)
                }
            }
            .frame(width: Self.listWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: Palette.sidebarBackground))
            Rectangle().fill(Color(nsColor: Palette.sidebarEdge)).frame(width: 1)
            VStack(spacing: 0) {
                header
                previewArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: Palette.pageBackground))
        }
        .foregroundStyle(Color(nsColor: Palette.textPrimary))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("version-history")
        .modifier(VersionRestoreDialogLayer(history: history, linkedPages: linkedPages, mentions: mentions,
                                            headerAddons: headerAddons, restore: restore))
        .onAppear { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let selected = history.selected {
                Text(history.timeText(selected))
                    .font(.system(size: 14, weight: .medium))
                    .accessibilityIdentifier("version-preview-time")
                if history.isCurrentSelected {
                    Text("Текущая версия")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: Palette.textSecondary))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: Palette.hoverBackground), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            Spacer()
            Button { history.isRestoreDialogShown = true } label: {
                Label("Восстановить", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color(nsColor: Palette.primaryButtonFill), in: RoundedRectangle(cornerRadius: 6))
                    .opacity(history.isCurrentSelected || history.selected == nil ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(history.isCurrentSelected || history.selected == nil)
            .accessibilityIdentifier("version-begin-restore")
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(nsColor: Palette.windowToolbarIcon))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Закрыть историю версий")
            .accessibilityIdentifier("version-history-close")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Palette.sidebarEdge)).frame(height: 1) }
    }

    @ViewBuilder
    private var previewArea: some View {
        if let preview = history.preview {
            VersionPreviewView(document: preview.document, highlightedBlockIds: preview.highlightedBlockIds, linkedPages: linkedPages,
                               mentions: mentions, headerAddons: headerAddons)
                .id(preview.versionId)
        } else {
            Text(history.errorText ?? "Версий пока нет")
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Список версий: «История версий», название страницы, «Группировать: 1 мин ▾» и строки «время / • Mac».
private struct VersionListPanel: View {
    @Bindable var history: VersionHistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("История версий").font(.system(size: 12)).foregroundStyle(Color(nsColor: Palette.textSecondary))
                Text(history.pageTitle).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            groupingMenu
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(history.rows) { version in
                            VersionRow(history: history, version: version)
                                .id(version.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .onAppear { if let id = history.selectedId { proxy.scrollTo(id) } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("version-list")
    }

    private var groupingMenu: some View {
        Menu {
            Section("Группировать изменения") {
                ForEach(VersionGrouping.allCases) { grouping in
                    Button { history.grouping = grouping } label: {
                        if grouping == history.grouping { Label(grouping.title, systemImage: "checkmark") } else { Text(grouping.title) }
                    }
                    .accessibilityIdentifier("version-grouping-\(grouping.rawValue)")
                }
            }
        } label: {
            Text("Группировать: \(history.grouping.shortTitle)").font(.system(size: 12))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(nsColor: Palette.hoverBackground), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityIdentifier("version-grouping")
    }
}

/// Строка версии; у выбранной — подложка и «›» раскрытия.
private struct VersionRow: View {
    let history: VersionHistoryModel
    let version: PageVersionInfo

    private var isSelected: Bool { history.selectedId == version.id }

    var body: some View {
        HStack(spacing: 6) {
            VersionAuthorStamp(time: history.timeText(version), deviceName: version.deviceName)
            Spacer(minLength: 0)
            if isSelected {
                Button { history.isExpanded = true } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(nsColor: Palette.textSecondary))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color(nsColor: Palette.border)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Что менялось")
                .accessibilityIdentifier("version-expand")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(isSelected ? Color(nsColor: Palette.hoverBackground) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottom) {
            if !isSelected { Rectangle().fill(Color(nsColor: Palette.sidebarEdge)).frame(height: 1).padding(.horizontal, 10) }
        }
        .contentShape(Rectangle())
        .onTapGesture { history.select(version.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("version-row")
    }
}

/// Время и «• имя Mac» серым.
private struct VersionAuthorStamp: View {
    let time: String
    let deviceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(time).font(.system(size: 14))
            HStack(spacing: 4) {
                Circle().fill(Color(nsColor: Palette.primaryButtonFill)).frame(width: 6, height: 6)
                Text(deviceName).font(.system(size: 12)).foregroundStyle(Color(nsColor: Palette.textSecondary)).lineLimit(1)
            }
        }
    }
}

/// Раскрытая версия (≈ `notion-version-details.png`): «← Все версии», карточка версии и что менялось.
private struct VersionDetailsPanel: View {
    let history: VersionHistoryModel
    let version: PageVersionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { history.isExpanded = false } label: {
                Label("Все версии", systemImage: "arrow.left").font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .accessibilityIdentifier("version-all-versions")
            card { VersionAuthorStamp(time: history.timeText(version), deviceName: version.deviceName) }
            card {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(version.summary.lines, id: \.self) { line in
                        Text(verbatim: "\(version.deviceName) \(line)").font(.system(size: 13))
                    }
                    Text(history.timeText(version)).font(.system(size: 12)).foregroundStyle(Color(nsColor: Palette.textSecondary))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("version-changes")
            Spacer()
        }
        .padding(.horizontal, 10)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(nsColor: Palette.pageBackground), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: Palette.border)))
    }
}
