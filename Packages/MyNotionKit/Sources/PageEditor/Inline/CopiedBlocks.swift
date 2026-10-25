import AppKit
import NotesCore

/// Копирование нескольких блоков внутри MyNotion, как в Notion: свой тип в буфере — блоки выделения в JSON с видами,
/// вложенностью, оформлением, ссылками и упоминаниями. Первый и последний блок — только выделенной частью; таблицы
/// и колонки — со своим содержимым. Для других программ рядом лежат Markdown простым текстом и HTML
/// (`copiedBlocksWriter`). Выделение внутри одного блока — по-прежнему `inlineTextPasteboardType`.
extension PageTextView {
    static let blocksPasteboardType = NSPasteboard.PasteboardType("ru.kurilov.mynotion.blocks")

    /// Блоки выделения → Markdown и HTML для других программ; `pageTitle` — название страницы упоминания.
    public typealias CopiedBlocksWriter = @MainActor (_ blocks: [Block], _ pageTitle: (UUID) -> String?) -> (markdown: String, html: String)

    /// Скопированный блок: всё, кроме часов синхронизации. Блоки потока — без `containerId`.
    struct CopiedBlock: Codable, Equatable {
        var id: UUID
        var kind: BlockKind
        var text: InlineText
        var indent: Int
        var isChecked: Bool
        var linkedPageId: UUID?
        var sortKey: FractionalSortKey
        var containerId: UUID?
        var color: BlockColor
        var props: BlockProps

        init(_ block: Block, containerId: UUID?) {
            id = block.id
            kind = block.kind
            text = block.text
            indent = block.indent
            isChecked = block.isChecked
            linkedPageId = block.linkedPageId
            sortKey = block.sortKey
            self.containerId = containerId
            color = block.color
            props = block.props
        }

        func block(pageId: UUID) -> Block {
            Block(id: id, pageId: pageId, kind: kind, text: text, indent: indent, isChecked: isChecked, linkedPageId: linkedPageId,
                  sortKey: sortKey, containerId: containerId, color: color, props: props)
        }
    }

    /// Блоки выделения; `nil` — выделение внутри одного блока (не в режиме блоков) или пустое.
    func copiedBlocks() -> [CopiedBlock]? {
        let ranges = selectedRanges.map(\.rangeValue)
        guard ranges.count == 1, let selection = ranges.first, selection.length > 0, let indices = selectedBlocks ?? selectedBlockRange(),
              indices.count > 1 || isBlockSelection else { return nil }
        let blocks = document.blocks
        let startOffset = selection.location - mapper.paragraphStart(ofBlockAt: indices.lowerBound)
        let endOffset = NSMaxRange(selection) - mapper.paragraphStart(ofBlockAt: indices.upperBound - 1)
        let baseIndent = indices.map { blocks[$0].indent }.min() ?? 0
        var copied: [CopiedBlock] = []
        for index in indices {
            var block = blocks[index]
            block.indent -= baseIndent
            if block.kind.holdsPastedText {
                let length = (block.text.string as NSString).length
                let lower = index == indices.lowerBound ? max(0, startOffset) : 0
                let upper = index == indices.upperBound - 1 ? min(length, endOffset) : length
                // Выделение от конца строки захватывает только её перевод строки, не сам блок.
                if index == indices.lowerBound, index < indices.upperBound - 1, length > 0, lower >= length { continue }
                block.text = block.text.slice(lower..<max(lower, upper))
            }
            // Подстраница и база — у страницы одно место: копия становится упоминанием.
            if block.kind.linksPage, let pageId = block.linkedPageId {
                block = Block(id: block.id, pageId: block.pageId, kind: .paragraph, text: InlineText.mention(pageId),
                              indent: block.indent, sortKey: block.sortKey)
            }
            copied.append(CopiedBlock(block, containerId: nil))
            copied += contents(of: block.id)
        }
        return copied
    }

    /// Содержимое таблицы или колонок — со всеми вложенными потоками.
    private func contents(of containerId: UUID) -> [CopiedBlock] {
        document.flow(containerId).flatMap { [CopiedBlock($0, containerId: containerId)] + contents(of: $0.id) }
    }

    /// Свой тип, Markdown или HTML блоков выделения; `false` — выделение не из нескольких блоков.
    func writeCopiedBlocks(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let copied = copiedBlocks() else { return false }
        if type == Self.blocksPasteboardType {
            guard let data = try? JSONEncoder().encode(copied) else { return false }
            return pboard.setData(data, forType: type)
        }
        guard let writer = copiedBlocksWriter else { return false }
        let directory = mentionDirectory
        let text = writer(copied.map { $0.block(pageId: document.pageId) }) { directory.plainTitle(of: $0) }
        switch type {
        case .string: return pboard.setString(text.markdown, forType: .string)
        case .html: return pboard.setString(text.html, forType: .html)
        default: return false
        }
    }

    /// Вставка блоков, скопированных в MyNotion: у всех блоков новые id (содержимое — в своих новых контейнерах),
    /// страница — эта, у дат — новые id. `false` — своего типа нет или блоки здесь не встают.
    func pasteCopiedBlocks(from pasteboard: NSPasteboard, replacing selection: NSRange) -> Bool {
        guard allowsBlockStructure, let data = pasteboard.data(forType: Self.blocksPasteboardType),
              let copied = try? JSONDecoder().decode([CopiedBlock].self, from: data), !copied.isEmpty else { return false }
        let newIds = Dictionary(copied.map { ($0.id, UUID.timeOrdered()) }, uniquingKeysWith: { first, _ in first })
        let blocks = copied.map { copy in
            var copy = copy
            copy.id = newIds[copy.id] ?? .timeOrdered()
            copy.containerId = copy.containerId.flatMap { newIds[$0] }
            copy.text = copy.text.withNewDateIds()
            return copy.block(pageId: document.pageId)
        }
        return pasteBlocks(blocks, replacing: selection)
    }
}

private extension InlineText {
    static func mention(_ pageId: UUID) -> InlineText {
        InlineText("\u{FFFC}", runs: [StyledRun(start: 0, length: 1, style: .mention(pageId))])
    }
}
