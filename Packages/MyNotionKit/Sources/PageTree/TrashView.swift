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

/// Корзина: удалённые страницы (каждая — со своими подстраницами), вернуть, удалить навсегда, очистить.
/// Удаление навсегда не отменяется, поэтому сначала спрашивает.
struct TrashView: View {
    let entries: [Page]
    let actions: TrashActions

    @State private var pendingErase: PendingErase?

    private enum PendingErase: Identifiable {
        case page(Page)
        case everything

        var id: String {
            switch self {
            case .page(let page): page.id.uuidString
            case .everything: "everything"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Корзина")
                .font(Font(Typography.sidebarGroupHeader.font))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .padding(.horizontal, Metrics.Sidebar.rowHorizontalPadding)
                .frame(height: Metrics.Sidebar.rowHeight, alignment: .leading)

            if entries.isEmpty {
                Text("Корзина пуста")
                    .font(Font(Typography.sidebarRow.font))
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
                    .padding(.horizontal, Metrics.Sidebar.rowHorizontalPadding)
                    .frame(height: Metrics.Sidebar.rowHeight, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { page in row(page) }
                    }
                }
                .frame(maxHeight: Metrics.Sidebar.trashPopoverMaxHeight)

                Rectangle()
                    .fill(Color(nsColor: Palette.border))
                    .frame(height: 1)
                    .padding(.vertical, Metrics.Sidebar.rowVerticalPadding)

                Button { pendingErase = .everything } label: {
                    Text("Очистить корзину")
                        .font(Font(Typography.sidebarRow.font))
                        .foregroundStyle(Color(nsColor: Palette.sidebarText))
                        .padding(.horizontal, Metrics.Sidebar.rowHorizontalPadding)
                        .frame(maxWidth: .infinity, minHeight: Metrics.Sidebar.rowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SidebarRowButtonStyle())
                .accessibilityIdentifier("trash-empty")
            }
        }
        .padding(Metrics.Sidebar.panelInset)
        .frame(width: Metrics.Sidebar.trashPopoverWidth)
        .background(Color(nsColor: Palette.pageBackground))
        .alert(item: $pendingErase) { pending in
            switch pending {
            case .page(let page):
                Alert(
                    title: Text("Удалить «\(page.displayTitle)» навсегда?"),
                    message: Text("Страница и её подстраницы сотрутся. Вернуть их будет нельзя."),
                    primaryButton: .destructive(Text("Удалить навсегда")) { actions.deleteForever(page.id) },
                    secondaryButton: .cancel(Text("Отмена"))
                )
            case .everything:
                Alert(
                    title: Text("Очистить корзину?"),
                    message: Text("Все страницы из корзины сотрутся. Вернуть их будет нельзя."),
                    primaryButton: .destructive(Text("Очистить")) { actions.emptyTrash() },
                    secondaryButton: .cancel(Text("Отмена"))
                )
            }
        }
    }

    private func row(_ page: Page) -> some View {
        HStack(spacing: Metrics.Sidebar.rowIconSpacing) {
            Group {
                if let icon = page.icon {
                    Text(icon).font(.system(size: Metrics.Sidebar.rowEmojiFontSize))
                } else {
                    Image(nsImage: DocumentGlyph.image(size: Metrics.Sidebar.rowIconSize))
                }
            }
            .frame(width: Metrics.Sidebar.rowIconSize, height: Metrics.Sidebar.rowIconSize)

            Text(page.displayTitle)
                .font(Font(Typography.sidebarRow.font))
                .foregroundStyle(Color(nsColor: Palette.textPrimary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            iconButton("arrow.uturn.backward", label: "Вернуть", identifier: "trash-restore") { actions.restore(page.id) }
            iconButton("trash", label: "Удалить навсегда", identifier: "trash-delete-forever") { pendingErase = .page(page) }
        }
        .padding(.horizontal, Metrics.Sidebar.rowHorizontalPadding)
        .frame(height: Metrics.Sidebar.rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trash-entry")
        .accessibilityLabel(page.displayTitle)
    }

    private func iconButton(_ symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Metrics.Sidebar.disclosureSymbolSize + 2, weight: .semibold))
                .foregroundStyle(Color(nsColor: Palette.handleIcon))
                .frame(width: Metrics.Sidebar.rowAccessorySize, height: Metrics.Sidebar.rowAccessorySize)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}
