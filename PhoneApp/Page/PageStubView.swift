import NotesCore
import PhoneShell
import SwiftUI

/// Временный экран страницы, пока нет редактора: иконка, название и текст блоков только для чтения.
/// Перечитывается, когда приходят правки с других устройств.
struct PageStubView: View {
    let pageId: UUID
    let library: PhoneLibrary
    @State private var content: PageContent?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let page = content?.page {
                    if let icon = page.icon {
                        Text(icon).font(.system(size: 56)).padding(.bottom, 4)
                    }
                    Text(page.displayTitle)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(page.title.isEmpty ? PhoneTheme.textSecondary : PhoneTheme.textPrimary)
                        .padding(.bottom, 10)
                        .accessibilityIdentifier("page-title")
                }
                ForEach(Array(flowBlocks.enumerated()), id: \.element.id) { index, block in
                    BlockLine(block: block, number: number(at: index), linkedTitle: linkedTitle(block))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PhoneTheme.pageHorizontalPadding)
            .padding(.vertical, 12)
        }
        .background(PhoneTheme.pageBackground)
        .accessibilityIdentifier("page-stub")
        .task(id: reloadKey) { content = try? library.store.pageContent(pageId) }
    }

    /// Перечитать при смене страницы, своих операциях с деревом и пришедших правках.
    private var reloadKey: [Int] {
        [pageId.hashValue, library.browser.revision, library.sync.remoteChangeCount]
    }

    /// Блоки потока страницы: колонки и таблицы заглушка не раскладывает.
    private var flowBlocks: [Block] {
        content?.blocks.filter { $0.containerId == nil } ?? []
    }

    /// Номер пункта нумерованного списка среди соседей подряд.
    private func number(at index: Int) -> Int {
        var number = 1
        var current = index - 1
        let block = flowBlocks[index]
        while current >= 0, flowBlocks[current].kind == .numberedItem, flowBlocks[current].indent == block.indent {
            number += 1
            current -= 1
        }
        return number
    }

    private func linkedTitle(_ block: Block) -> String? {
        guard block.kind == .pageLink, let id = block.linkedPageId else { return nil }
        return library.browser.page(id)?.pathTitle ?? Page.untitledTitle
    }
}

/// Строка блока: вид по типу, как на странице Mac, но без правки.
private struct BlockLine: View {
    let block: Block
    let number: Int
    let linkedTitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker
            text
        }
        .padding(.leading, CGFloat(block.indent) * 24)
        .padding(.top, topPadding)
    }

    @ViewBuilder
    private var marker: some View {
        switch block.kind {
        case .bulletItem: Text("•").foregroundStyle(PhoneTheme.textPrimary)
        case .numberedItem: Text("\(number).").foregroundStyle(PhoneTheme.textPrimary).monospacedDigit()
        case .checkbox:
            Image(systemName: block.isChecked ? "checkmark.square.fill" : "square")
                .foregroundStyle(block.isChecked ? PhoneTheme.accent : PhoneTheme.icon)
        case .toggle: Image(systemName: "chevron.right").font(.caption).foregroundStyle(PhoneTheme.icon)
        case .pageLink: Image(systemName: "doc.text").foregroundStyle(PhoneTheme.icon)
        case .quote: Rectangle().fill(PhoneTheme.textPrimary).frame(width: 3, height: 22)
        default: EmptyView()
        }
    }

    @ViewBuilder
    private var text: some View {
        switch block.kind {
        case .divider:
            Rectangle().fill(PhoneTheme.border).frame(height: 1).frame(maxWidth: .infinity).padding(.vertical, 8)
        case .pageLink:
            Text(linkedTitle ?? Page.untitledTitle).underline().foregroundStyle(PhoneTheme.textPrimary)
        case .code, .equation:
            Text(block.text.string)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PhoneTheme.groupedBackground, in: RoundedRectangle(cornerRadius: 6))
        default:
            Text(block.text.string)
                .font(font)
                .foregroundStyle(block.kind == .checkbox && block.isChecked ? PhoneTheme.textSecondary : PhoneTheme.textPrimary)
                .strikethrough(block.kind == .checkbox && block.isChecked)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var font: Font {
        switch block.kind {
        case .heading1: .system(size: 26, weight: .bold)
        case .heading2: .system(size: 22, weight: .semibold)
        case .heading3: .system(size: 19, weight: .semibold)
        default: .system(size: 17)
        }
    }

    private var topPadding: CGFloat {
        switch block.kind {
        case .heading1: 18
        case .heading2: 14
        case .heading3: 10
        default: 2
        }
    }
}
