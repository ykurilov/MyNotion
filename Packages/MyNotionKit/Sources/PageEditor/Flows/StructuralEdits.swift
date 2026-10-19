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
        layoutEmbeddedViews()
        flowEditors(inColumnList: list.id).first?.focus(atEnd: false)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
