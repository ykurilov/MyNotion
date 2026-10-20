import AppKit
import NotesCore

extension PageTextView {
    /// Правка нескольких потоков одним шагом ⌘Z (колонки, таблица, перенос между потоками): документ применяет её
    /// и возвращает обратную, отмена применяет обратную тем же путём. Все редакторы страницы перерисовывают свои потоки
    /// сами; общая отмена окна при этом не сбрасывается — правка сделана от её имени.
    func applyStructuralChanges(_ changes: BlockChanges, actionName: String) {
        guard !changes.isEmpty else { return }
        for editor in pageEditor.editorTree { editor.commitEdits() }
        breakUndoCoalescing()
        let undoManager = undoManager
        let inverse = document.pageDocument.apply(changes, origin: undoManager ?? self)
        guard let undoManager else { return }
        let target = pageEditor
        undoManager.registerUndo(withTarget: target) { editor in
            editor.applyStructuralChanges(inverse, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    /// Блоки `ids` (корень и его поддерево) — колонкой справа от блока `targetId`.
    @discardableResult
    func placeBlocks(_ ids: [UUID], besideRightOf targetId: UUID) -> Bool {
        guard let changes = document.pageDocument.changesPlacing(ids, besideRightOf: targetId) else { return false }
        applyStructuralChanges(changes, actionName: "Колонки")
        return true
    }

    /// Блоки `ids` — в поток `containerId` (`nil` — поток страницы) между `previousId` и `nextId`.
    func moveBlocks(_ ids: [UUID], to containerId: UUID?, after previousId: UUID?, before nextId: UUID?, rootIndent: Int = 0) {
        applyStructuralChanges(document.pageDocument.changesMoving(ids, to: containerId, after: previousId, before: nextId,
                                                                    rootIndent: rootIndent),
                               actionName: "Переместить блок")
    }

    /// «Дублировать» (⌘D, меню блока): копии блоков `range` со всем вложенным — детьми, колонками, ячейками таблиц —
    /// встают сразу под ними одним шагом ⌘Z. У копий новые id; ячейки ссылаются на копии своих столбцов; пометки переноса
    /// (`movedFrom`) у копий нет — восстановление версии страницы, откуда принесли оригинал, копию не удаляет.
    /// Подстраница не дублируется: у страницы одна ссылка (data-model.md).
    func duplicateBlocks(at range: Range<Int>) {
        commitEdits()
        let blocks = document.blocks
        guard !range.isEmpty, range.upperBound <= blocks.count else { return }
        let end = BlockMoveController.subtreeEnd(blocks, of: range.upperBound - 1)
        let originals = blocks[range.lowerBound..<end].filter { $0.kind != .pageLink }
        guard !originals.isEmpty else { return }
        var newIds: [UUID: UUID] = [:]
        var copies: [Block] = []
        func copy(_ block: Block, sortKey: FractionalSortKey, containerId: UUID?) {
            let id = UUID.timeOrdered()
            newIds[block.id] = id
            var props = block.props
            props.movedFrom = nil
            copies.append(Block(id: id, pageId: document.pageId, kind: block.kind, text: block.text, indent: block.indent,
                                isChecked: block.isChecked, sortKey: sortKey, containerId: containerId, color: block.color,
                                props: props))
            for inner in document.pageDocument.flow(block.id) { copy(inner, sortKey: inner.sortKey, containerId: id) }
        }
        var key = blocks[end - 1].sortKey
        let upper = blocks[safe: end]?.sortKey
        for block in originals {
            key = .between(key, upper)
            copy(block, sortKey: key, containerId: document.containerId)
        }
        // Ячейка таблицы помнит свой столбец по id: у копии — копия столбца.
        for index in copies.indices {
            if let column = copies[index].props.columnId, let copied = newIds[column] { copies[index].props.columnId = copied }
        }
        applyStructuralChanges(BlockChanges(upserts: copies), actionName: "Дублировать")
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        blockViews.update()
    }

    /// «/» → «Колонки: N»: пустой блок сам становится колонками, под блоком с текстом колонки встают ниже.
    /// В каждой колонке — пустой абзац, курсор — в первой.
    func insertColumns(_ count: Int, at index: Int) {
        commitEdits()
        let blocks = document.blocks
        guard blocks.indices.contains(index) else { return }
        let block = blocks[index]
        let pageId = document.pageId
        var changes = BlockChanges()
        let key: FractionalSortKey
        if block.text.string.isEmpty, block.kind == .paragraph {
            key = block.sortKey
            changes.removals.append(block.id)
        } else {
            key = .between(block.sortKey, blocks[safe: index + 1]?.sortKey)
        }
        let list = Block(pageId: pageId, kind: .columnList, indent: block.indent, sortKey: key, containerId: document.containerId)
        changes.upserts.append(list)
        var columnKey: FractionalSortKey?
        var firstColumn: UUID?
        for _ in 0..<min(max(count, 2), ColumnLayout.maximumColumns) {
            columnKey = .between(columnKey, nil)
            let column = Block(pageId: pageId, kind: .column, sortKey: columnKey!, containerId: list.id)
            firstColumn = firstColumn ?? column.id
            changes.upserts += [column, Block(pageId: pageId, sortKey: .between(nil, nil), containerId: column.id)]
        }
        // Под колонками в конце потока — пустой абзац: писать дальше есть где.
        if index + 1 == blocks.count {
            changes.upserts.append(Block(pageId: pageId, sortKey: .between(key, nil), containerId: document.containerId))
        }
        applyStructuralChanges(changes, actionName: "Колонки")
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        blockViews.update()
        flowEditors(inColumnList: list.id).first?.focus(atEnd: false)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
