import AppKit
import NotesCore
import PageEditor
import PageVersions
import SwiftUI
import VisualStyle

/// «История версий» на всё окно под строкой вкладок, как у Notion 7.39 (`Metrics.VersionHistory`, замер 21.10.2026):
/// слева 320 — список версий с группировкой или раскрытая версия; справа — строка времени с «Восстановить» и «×»,
/// под ней версия «только чтение» с подсветкой отличий. Esc и «×» закрывают.
struct VersionHistoryView: View {
    @Bindable var history: VersionHistoryModel
    /// Справочник страниц и упоминаний — как у открытой страницы.
    let linkedPages: [UUID: LinkedPage]
    let mentions: MentionSettings
    let headerAddons: [PageHeaderAddonFactory]
    let close: () -> Void
    let restore: (UUID) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if history.isExpanded, let selected = history.selected {
                    VersionDetailsPanel(history: history, version: selected)
                } else {
                    VersionListPanel(history: history)
                }
            }
            .frame(width: Metrics.VersionHistory.panelWidth)
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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(nsColor: Palette.textSecondary))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: Palette.hoverBackground), in: RoundedRectangle(cornerRadius: 4))
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
            // Пока открыто окно восстановления или список группировки, Esc закрывает их, а не историю.
            .keyboardShortcut(history.isRestoreDialogShown || history.isGroupingMenuShown ? nil : .cancelAction)
            .accessibilityLabel("Закрыть историю версий")
            .accessibilityIdentifier("version-history-close")
        }
        .padding(.leading, Metrics.VersionHistory.previewHeaderInset)
        .padding(.trailing, 12)
        .frame(height: Metrics.VersionHistory.previewHeaderHeight)
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
    /// Где кнопка группировки в панели: список встаёт под ней.
    @State private var groupingFrame: CGRect = .zero

    private typealias Layout = Metrics.VersionHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("История версий").font(.system(size: 12)).foregroundStyle(Color(nsColor: Palette.textSecondary))
                Text(history.pageTitle).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, Layout.headerInset)
            .padding(.top, Layout.headerTop)
            VersionGroupingButton(history: history)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: GroupingButtonFrame.self, value: proxy.frame(in: .named(Self.space)))
                })
                .padding(.horizontal, Layout.headerInset)
                .padding(.top, 8)
                .padding(.bottom, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(history.rows) { version in
                            VersionRow(history: history, version: version)
                                .id(version.id)
                        }
                    }
                    .padding(.horizontal, Layout.listInset)
                    .padding(.bottom, 10)
                }
                .onAppear { if let id = history.selectedId { proxy.scrollTo(id) } }
            }
        }
        .overlay(alignment: .topLeading) {
            if history.isGroupingMenuShown { VersionGroupingMenu(history: history, below: groupingFrame) }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(GroupingButtonFrame.self) { groupingFrame = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("version-list")
    }

    private static let space = "version-list-panel"
}

private struct GroupingButtonFrame: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// «Группировать: 1 мин ▾» — серая подпись, значение цветом текста, стрелка вниз (как «Group by 1m ▾» у Notion).
private struct VersionGroupingButton: View {
    @Bindable var history: VersionHistoryModel

    private typealias Layout = Metrics.VersionHistory

    var body: some View {
        Button { history.isGroupingMenuShown.toggle() } label: {
            HStack(spacing: 4) {
                Text("Группировать:").foregroundStyle(Color(nsColor: Palette.textSecondary))
                Text(history.grouping.shortTitle).fontWeight(.medium).foregroundStyle(Color(nsColor: Palette.textPrimary))
                Image(systemName: "chevron.down")
                    .font(.system(size: Layout.groupingChevronSize, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
                    .accessibilityIdentifier("version-grouping-chevron")
            }
            .font(.system(size: 12))
            .padding(.horizontal, Layout.groupingPadding)
            .frame(height: Layout.groupingHeight)
            .background(Color(nsColor: Palette.hoverBackground), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityIdentifier("version-grouping")
    }
}

/// Открытый список группировки (как «Group changes by» у Notion 7.39): карточка 180 под кнопкой, заголовок и строки 28,
/// у выбранной — галочка справа. Щелчок мимо и Esc закрывают.
private struct VersionGroupingMenu: View {
    @Bindable var history: VersionHistoryModel
    /// Кнопка группировки в координатах панели.
    let below: CGRect

    private typealias Layout = Metrics.VersionHistory

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { history.isGroupingMenuShown = false }
            VStack(alignment: .leading, spacing: 1) {
                Text("Группировать изменения")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                ForEach(VersionGrouping.allCases) { grouping in
                    Button {
                        history.grouping = grouping
                        history.isGroupingMenuShown = false
                    } label: {
                        HStack {
                            Text(grouping.title).font(.system(size: 14))
                            Spacer(minLength: 8)
                            if grouping == history.grouping {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .medium))
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(grouping == history.grouping ? Color(nsColor: Palette.hoverBackground) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("version-grouping-\(grouping.rawValue)")
                }
            }
            .padding(4)
            .padding(.top, 2)
            .frame(width: Layout.groupingMenuWidth)
            .background(PopupSurfaceBackground())
            .offset(x: below.minX, y: below.maxY + Layout.groupingMenuGap)
            .onExitCommand { history.isGroupingMenuShown = false }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("version-grouping-menu")
        }
    }
}

/// Строка версии 64 (как у Notion): у выбранной — подложка и «›» раскрытия, между остальными — линия.
private struct VersionRow: View {
    let history: VersionHistoryModel
    let version: PageVersionInfo

    private var isSelected: Bool { history.selectedId == version.id }
    private typealias Layout = Metrics.VersionHistory

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
        .padding(.horizontal, Layout.rowPadding)
        .frame(height: Layout.rowHeight)
        .background(isSelected ? Color(nsColor: Palette.hoverBackground) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottom) {
            if !isSelected { Rectangle().fill(Color(nsColor: Palette.sidebarEdge)).frame(height: 1).padding(.horizontal, Layout.rowPadding) }
        }
        .contentShape(Rectangle())
        .onTapGesture { history.select(version.id) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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

/// Раскрытая версия, как у Notion 7.39 (`notion-version-details.png`, замер 21.10.2026): «← Все версии», карточка версии,
/// от неё линия к записи изменений — аватар 16, жирное имя Mac и серым что менялось, ниже время.
private struct VersionDetailsPanel: View {
    let history: VersionHistoryModel
    let version: PageVersionInfo

    private typealias Layout = Metrics.VersionHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { history.isExpanded = false } label: {
                Label("Все версии", systemImage: "arrow.left").font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Layout.rowPadding)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .accessibilityIdentifier("version-all-versions")
            VersionAuthorStamp(time: history.timeText(version), deviceName: version.deviceName)
                .padding(.horizontal, Layout.rowPadding)
                .frame(maxWidth: .infinity, minHeight: Layout.rowHeight - 14, alignment: .leading)
                .background(Color(nsColor: Palette.hoverBackground), in: RoundedRectangle(cornerRadius: 10))
            // Линия от карточки версии к записи изменений — по середине аватара.
            Rectangle()
                .fill(Color(nsColor: Palette.dividerLine))
                .frame(width: Layout.threadLineWidth, height: 12)
                .padding(.leading, Layout.rowPadding + Layout.avatarSize / 2)
                .accessibilityIdentifier("version-thread-line")
            HStack(alignment: .top, spacing: 8) {
                VersionAvatar(deviceName: version.deviceName)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(version.summary.lines, id: \.self) { line in
                        (Text(verbatim: version.deviceName).fontWeight(.medium).foregroundColor(Color(nsColor: Palette.textPrimary))
                         + Text(verbatim: " \(line)").foregroundColor(Color(nsColor: Palette.textSecondary)))
                            .font(.system(size: 14))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(history.timeText(version)).font(.system(size: 12)).foregroundStyle(Color(nsColor: Palette.textSecondary))
                }
            }
            .padding(.horizontal, Layout.rowPadding)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("version-changes")
            Spacer()
        }
        .padding(.horizontal, Layout.listInset)
    }
}

/// Аватар автора версии: круг 16 с первой буквой имени Mac (у Notion — фото пользователя).
private struct VersionAvatar: View {
    let deviceName: String

    var body: some View {
        Text(String(deviceName.first ?? "M").uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Metrics.VersionHistory.avatarSize, height: Metrics.VersionHistory.avatarSize)
            .background(Circle().fill(Color(nsColor: Palette.primaryButtonFill)))
            .padding(.top, 1)
            .accessibilityIdentifier("version-avatar")
    }
}

/// Фон карточки — как у всплывающих меню: фон меню, рамка 1, мягкая тень, скругление 10.
private struct PopupSurfaceBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.PopupMenu.cornerRadius)
            .fill(Color(nsColor: Palette.popupMenuBackground))
            .overlay(RoundedRectangle(cornerRadius: Metrics.PopupMenu.cornerRadius).strokeBorder(Color(nsColor: Palette.newTabCardRing)))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 8)
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}
