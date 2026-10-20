import AppKit
import NotesCore
import SwiftUI
import VisualStyle

/// Окно «Переместить в…», как «Move page to…» у Notion 7.39 (`notion-move-to.png`): поле с лупой и синей рамкой,
/// без запроса — «Недавние», затем «Страницы» деревом с «›»; с запросом — выдача поиска. Недоступная строка — серая.
public struct PagePickerView: View {
    public static let width: CGFloat = 262
    static let maxListHeight: CGFloat = 320
    static let rowHeight: CGFloat = 28
    static let depthStep: CGFloat = 14

    @Bindable var model: PagePickerModel
    @FocusState private var isFieldFocused: Bool

    public init(model: PagePickerModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            field
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)
            list
        }
        .frame(width: Self.width)
        .background(Color(nsColor: Palette.popupMenuBackground), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: Palette.border)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page-picker")
        .onAppear {
            // Следующий оборот цикла: поле уже в окне, и фокус уходит в него.
            DispatchQueue.main.async { isFieldFocused = true }
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
            TextField(model.placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFieldFocused)
                .onSubmit { model.handle(.enter) }
                .onKeyPress(.downArrow) { handled(model.handle(.down)) }
                .onKeyPress(.upArrow) { handled(model.handle(.up)) }
                // Стрелки вбок раскрывают дерево, пока запроса нет; с запросом — двигают курсор в поле.
                .onKeyPress(.rightArrow) { model.query.isEmpty ? handled(model.handle(.right)) : .ignored }
                .onKeyPress(.leftArrow) { model.query.isEmpty ? handled(model.handle(.left)) : .ignored }
                .onKeyPress(.escape) { handled(model.handle(.escape)) }
                .accessibilityIdentifier("page-picker-field")
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color(nsColor: Palette.emojiSearchBackground), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: Palette.focusRing), lineWidth: 1.5))
    }

    private var list: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.rows.isEmpty {
                        Text(model.query.isEmpty ? "Страниц пока нет" : "Ничего не найдено")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(nsColor: Palette.textSecondary))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                    }
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if index == 0 || model.rows[index - 1].section != row.section, let title = Self.sectionTitle(row.section) {
                            sectionTitle(title)
                        }
                        rowView(row, index: index)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: Self.maxListHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: model.selectedIndex) { _, index in
                if let index, model.rows.indices.contains(index) { scroll.scrollTo(model.rows[index].id) }
            }
        }
    }

    static func sectionTitle(_ section: PagePickerRow.Section) -> String? {
        switch section {
        case .recent: "Недавние"
        case .pages: "Страницы"
        case .results: nil
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(nsColor: Palette.textSecondary))
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func rowView(_ row: PagePickerRow, index: Int) -> some View {
        PagePickerRowView(row: row, isSelected: model.selectedIndex == index,
                          toggle: { if case .page(let id) = row.target { model.toggleExpanded(id) } })
            .id(row.id)
            .onTapGesture { model.choose(at: index) }
            .onHover { if $0 { model.select(index) } }
    }

    private func handled(_ isHandled: Bool) -> KeyPress.Result { isHandled ? .handled : .ignored }
}

/// Строка: «›» раскрытия (у дерева), иконка, название; у выдачи — путь серым.
struct PagePickerRowView: View {
    let row: PagePickerRow
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if row.section == .pages {
                disclosure
            }
            icon
            Text(row.title)
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: row.isAvailable ? Palette.textPrimary : Palette.textSecondary))
                .lineLimit(1)
                .truncationMode(.tail)
            if let path = row.path, !path.isEmpty {
                Text(path)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6 + CGFloat(row.depth) * PagePickerView.depthStep)
        .padding(.trailing, 6)
        .frame(height: PagePickerView.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected && row.isAvailable ? Color(nsColor: Palette.hoverBackground) : .clear))
        .opacity(row.isAvailable ? 1 : 0.55)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("page-picker-row")
        .accessibilityLabel(row.title)
        .accessibilityValue(row.isAvailable ? "" : "недоступна")
    }

    @ViewBuilder private var disclosure: some View {
        if row.hasChildren {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }

    @ViewBuilder private var icon: some View {
        if row.target == .topLevel {
            Image(systemName: "arrow.up.to.line")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Palette.sidebarIcon))
                .frame(width: 18)
        } else if let emoji = row.icon, !emoji.isEmpty {
            Text(emoji).font(.system(size: 13)).frame(width: 18)
        } else {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Palette.sidebarIcon))
                .frame(width: 18)
        }
    }
}
