import AppKit
import NotesCore
import SwiftUI
import VisualStyle

/// Что корзина просит сделать окно (FR-005).
@MainActor
public struct TrashActions {
    public var restore: (UUID) -> Void
    public var deleteForever: (UUID) -> Void
    public var emptyTrash: () -> Void

    public init(restore: @escaping (UUID) -> Void, deleteForever: @escaping (UUID) -> Void, emptyTrash: @escaping () -> Void) {
        self.restore = restore
        self.deleteForever = deleteForever
        self.emptyTrash = emptyTrash
    }
}

/// Содержимое окна корзины: удалённые страницы (каждая — со своими подстраницами), вернуть, удалить навсегда, очистить.
/// Удаление навсегда не отменяется: спрашивает окно корзины (`confirmDeleteForever`, `confirmEmptyTrash`).
struct TrashView: View {
    let entries: [Page]
    let actions: TrashActions
    let confirmDeleteForever: (Page) -> Void
    let confirmEmptyTrash: () -> Void

    /// Высота содержимого без прокрутки: заголовок, строки, линия и «Очистить корзину» (или строка «пусто»).
    static func preferredHeight(entryCount: Int) -> CGFloat {
        let row = Metrics.Sidebar.rowHeight
        let inset = Metrics.TrashPanel.contentInset
        guard entryCount > 0 else { return 2 * inset + 2 * row }
        return 2 * inset + row + CGFloat(entryCount) * row + dividerHeight + row
    }

    private static let dividerHeight = 1 + 2 * Metrics.Sidebar.rowVerticalPadding

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Корзина")
                .font(Font(Typography.sidebarGroupHeader.font))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .padding(.horizontal, Metrics.Sidebar.rowHorizontalPadding)
                .frame(maxWidth: .infinity, minHeight: Metrics.Sidebar.rowHeight, maxHeight: Metrics.Sidebar.rowHeight,
                       alignment: .leading)

            if entries.isEmpty {
                Text("Корзина пуста")
                    .font(Font(Typography.sidebarRow.font))
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
                    .padding(.horizontal, Metrics.Sidebar.rowHorizontalPadding)
                    .frame(maxWidth: .infinity, minHeight: Metrics.Sidebar.rowHeight, maxHeight: Metrics.Sidebar.rowHeight,
                           alignment: .leading)
                    .accessibilityIdentifier("trash-empty-state")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { page in row(page) }
                    }
                }
                .frame(maxHeight: .infinity)

                Rectangle()
                    .fill(Color(nsColor: Palette.border))
                    .frame(height: 1)
                    .padding(.vertical, Metrics.Sidebar.rowVerticalPadding)

                Button(action: confirmEmptyTrash) {
                    EmptyTrashLabel()
                }
                .buttonStyle(SidebarRowButtonStyle())
                .accessibilityIdentifier("trash-empty")
            }
        }
        .padding(Metrics.TrashPanel.contentInset)
        .frame(width: Metrics.TrashPanel.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ page: Page) -> some View {
        HStack(spacing: Metrics.Sidebar.rowIconSpacing) {
            PageIconView(icon: page.icon)
            Text(page.displayTitle)
                .font(Font(Typography.sidebarRow.font))
                .foregroundStyle(Color(nsColor: Palette.textPrimary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Metrics.Sidebar.rowAccessorySpacing)
            iconButton("arrow.uturn.backward", label: "Вернуть", identifier: "trash-restore") { actions.restore(page.id) }
            iconButton("trash", label: "Удалить навсегда", identifier: "trash-delete-forever") { confirmDeleteForever(page) }
        }
        .padding(.leading, Metrics.Sidebar.rowHorizontalPadding)
        .padding(.trailing, Metrics.Sidebar.rowHorizontalPadding / 2)
        .frame(height: Metrics.Sidebar.rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trash-entry")
        .accessibilityLabel(page.displayTitle)
    }

    private func iconButton(_ symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Metrics.Sidebar.accessorySymbolSize, weight: .medium))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .frame(width: Metrics.Sidebar.rowAccessorySize, height: Metrics.Sidebar.rowAccessorySize)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(cornerRadius: Metrics.Sidebar.rowAccessoryCornerRadius))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// «Очистить корзину»: видно, что это действие; под мышью — красным.
private struct EmptyTrashLabel: View {
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Metrics.Sidebar.rowIconSpacing) {
            Image(systemName: "trash")
                .font(.system(size: Metrics.Sidebar.accessorySymbolSize, weight: .medium))
                .frame(width: Metrics.Sidebar.rowIconSize, height: Metrics.Sidebar.rowIconSize)
            Text("Очистить корзину")
                .font(Font(Typography.sidebarRow.font))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(nsColor: isHovered ? Palette.destructiveText : Palette.textPrimary))
        .padding(.horizontal, Metrics.Sidebar.rowHorizontalPadding)
        .frame(maxWidth: .infinity, minHeight: Metrics.Sidebar.rowHeight, maxHeight: Metrics.Sidebar.rowHeight)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// Иконка страницы в строке: эмодзи или значок документа, по центру квадрата 20×20.
struct PageIconView: View {
    let icon: String?

    var body: some View {
        Group {
            if let icon {
                Text(icon).font(.system(size: Metrics.Sidebar.rowEmojiFontSize))
            } else {
                Image(nsImage: DocumentGlyph.image(size: Metrics.Sidebar.rowIconSize))
            }
        }
        .frame(width: Metrics.Sidebar.rowIconSize, height: Metrics.Sidebar.rowIconSize)
    }
}
