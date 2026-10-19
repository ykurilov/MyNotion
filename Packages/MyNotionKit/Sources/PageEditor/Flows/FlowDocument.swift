import Foundation
import NotesCore

/// Документ глазами одного редактора (research R3): блоки его потока — поток страницы, колонка или одна ячейка таблицы.
/// Редактор страницы и редакторы колонок — один и тот же `PageTextView`: всё, что он делает с «блоками документа»,
/// идёт в свой поток. Остальное (страница, конфликты, название) — прямо из `PageDocument`.
@MainActor
@dynamicMemberLookup
public final class FlowDocument {
    public let pageDocument: PageDocument
    let source: Source

    enum Source: Equatable {
        /// Поток страницы.
        case page
        /// Поток контейнера: блоки колонки.
        case container(UUID)
        /// Одна ячейка таблицы: блок `tableCell` на пересечении строки и столбца. Ячейки может ещё не быть —
        /// тогда показывается пустой блок с id `cellId`, и первый ввод создаёт ячейку с этим id.
        case cell(table: UUID, row: UUID, column: UUID, cellId: UUID)
    }

    init(_ pageDocument: PageDocument, source: Source = .page) {
        self.pageDocument = pageDocument
        self.source = source
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<PageDocument, T>) -> T {
        pageDocument[keyPath: keyPath]
    }

    /// Контейнер потока; `nil` — поток страницы.
    var containerId: UUID? {
        switch source {
        case .page: nil
        case .container(let id): id
        case .cell(_, let row, _, _): row
        }
    }

    /// Чем поток помечен в `ExternalChange.changedFlowIds`: id контейнера, у потока страницы — id страницы.
    var flowKey: UUID { containerId ?? pageDocument.pageId }

    /// Блоки потока по порядку.
    public var blocks: [Block] {
        switch source {
        case .page: pageDocument.blocks
        case .container(let id): pageDocument.flow(id)
        case .cell: [cellBlock]
        }
    }

    public func index(ofBlock id: UUID) -> Int? {
        switch source {
        case .page: return pageDocument.index(ofBlock: id)
        case .container(let containerId):
            guard pageDocument.block(id)?.containerId == containerId else { return nil }
            return pageDocument.flow(containerId).firstIndex { $0.id == id }
        case .cell(_, _, _, let cellId): return id == cellBlock.id || id == cellId ? 0 : nil
        }
    }

    /// Блок любого потока страницы.
    public func block(_ id: UUID) -> Block? {
        if case .cell = source, id == cellBlock.id { return cellBlock }
        return pageDocument.block(id)
    }

    /// Заменить блоки своего потока (`PageDocument.replaceBlocks`). В ячейке поток — всегда один блок: абзацы черновиков
    /// склеиваются переносом строки, ячейки нет — она создаётся.
    @discardableResult
    public func replaceBlocks(after previousId: UUID?, before nextId: UUID?, with drafts: [BlockDraft],
                              movedBlockIds: Set<UUID> = [], origin: AnyObject? = nil) -> [UUID] {
        switch source {
        case .page:
            return pageDocument.replaceBlocks(after: previousId, before: nextId, with: drafts, movedBlockIds: movedBlockIds, origin: origin)
        case .container(let id):
            return pageDocument.replaceBlocks(in: id, after: previousId, before: nextId, with: drafts, movedBlockIds: movedBlockIds, origin: origin)
        case .cell(let table, _, _, let cellId):
            let text = drafts.map(\.text).reduce(into: InlineText.empty) { joined, text in
                joined = joined.string.isEmpty && joined.runs.isEmpty ? text : joined.appending(text, separator: "\n")
            }
            guard let grid = pageDocument.tableGrid(table), let (row, column) = cellPosition(in: grid) else { return [cellBlock.id] }
            pageDocument.apply(grid.settingText(text, row: row, column: column, newCellId: cellId), origin: origin)
            return [cellBlock.id]
        }
    }

    public func setText(_ text: InlineText, ofBlock blockId: UUID) {
        pageDocument.setText(text, ofBlock: blockId)
    }

    public func setTitle(_ title: String, origin: AnyObject? = nil) {
        pageDocument.setTitle(title, origin: origin)
    }

    public func adoptStoredTextVersion(ofBlock blockId: UUID) {
        pageDocument.adoptStoredTextVersion(ofBlock: blockId)
    }

    public func flow(_ containerId: UUID) -> [Block] {
        pageDocument.flow(containerId)
    }

    // MARK: Ячейка

    /// Блок ячейки: записанный или пустой с заранее данным id.
    var cellBlock: Block {
        guard case .cell(_, let row, let column, let cellId) = source else { preconditionFailure("не ячейка") }
        // Та же ячейка, что показывает таблица (`TableGrid`): первая в строке с id этого столбца.
        if let cell = pageDocument.flow(row).first(where: { $0.kind == .tableCell && $0.props.columnId == column }) { return cell }
        var props = BlockProps()
        props.columnId = column
        return Block(id: cellId, pageId: pageDocument.pageId, kind: .tableCell, sortKey: .between(nil, nil), containerId: row, props: props)
    }

    private func cellPosition(in grid: TableGrid) -> (row: Int, column: Int)? {
        guard case .cell(_, let row, let column, _) = source,
              let rowIndex = grid.rows.firstIndex(where: { $0.id == row }),
              let columnIndex = grid.columns.firstIndex(where: { $0.id == column }) else { return nil }
        return (rowIndex, columnIndex)
    }
}

extension InlineText {
    /// Этот текст, разделитель и `other`; оформление `other` сдвигается.
    func appending(_ other: InlineText, separator: String) -> InlineText {
        let shift = (string as NSString).length + (separator as NSString).length
        let runs = runs + other.runs.map { StyledRun(start: $0.start + shift, length: $0.length, style: $0.style) }
        return InlineText(string + separator + other.string, runs: runs).normalized()
    }
}
