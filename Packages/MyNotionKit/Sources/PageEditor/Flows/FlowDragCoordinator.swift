import AppKit
import NotesCore
import VisualStyle

/// Куда сбросить перетаскиваемый блок (research R3): между блоками любого редактора страницы или к правому краю блока —
/// тогда блок встаёт колонкой справа.
enum BlockDropTarget: Equatable {
    /// Место `index` в потоке `containerId` (`nil` — поток страницы).
    case gap(containerId: UUID?, index: Int)
    /// Колонкой справа от блока.
    case besideRight(UUID)
}

/// Перетаскивание «⋮⋮» над всеми редакторами страницы: место сброса ищется в том редакторе, над которым мышь, —
/// в тексте страницы, в колонке; сборка и распад колонок — одной правкой (`PageTextView.applyStructuralChanges`).
@MainActor
enum FlowDragCoordinator {
    /// Редактор под точкой окна: самый глубокий; в просвете между колонками — ближайшая колонка.
    static func editor(atWindowPoint point: NSPoint, in root: PageTextView) -> PageTextView {
        for view in root.embeddedContentViews {
            guard let columns = view as? ColumnsView, !columns.isHiddenOrHasHiddenAncestor, columns.window != nil else { continue }
            let local = columns.convert(point, from: nil)
            guard columns.bounds.insetBy(dx: -Metrics.Columns.gap / 2, dy: 0).contains(local) else { continue }
            if let nearest = columns.editors.min(by: { abs($0.frame.midX - local.x) < abs($1.frame.midX - local.x) }) {
                return editor(atWindowPoint: point, in: nearest)
            }
        }
        return root
    }

    static func dropTarget(forBlock blockId: UUID, atWindowPoint point: NSPoint, in root: PageTextView) -> BlockDropTarget? {
        let editor = editor(atWindowPoint: point, in: root)
        let document = editor.document
        // Внутрь самого себя (колонки — в свою колонку) не бросить.
        if let containerId = document.containerId, let container = document.pageDocument.block(containerId),
           containerId == blockId || document.pageDocument.containerChain(of: container).contains(blockId) { return nil }
        let local = editor.convert(point, from: nil)
        if let index = editor.blockIndex(atY: local.y), let frame = editor.blockFrame(ofBlockAt: index) {
            let target = document.blocks[index]
            let zone = Metrics.Columns.rightEdgeDropZone
            if local.x >= frame.maxX - zone, local.x <= frame.maxX + zone, target.id != blockId, target.kind != .columnList,
               document.pageDocument.changesPlacing(movedIds(of: blockId, in: root), besideRightOf: target.id) != nil {
                return .besideRight(target.id)
            }
        }
        guard let gap = editor.dropGap(atY: local.y) else { return nil }
        return .gap(containerId: document.containerId, index: gap.index)
    }

    /// Сбросить блок с вложенными на место под точкой. `false` — места нет.
    static func drop(_ blockId: UUID, atWindowPoint point: NSPoint, in root: PageTextView) -> Bool {
        guard let target = dropTarget(forBlock: blockId, atWindowPoint: point, in: root),
              let source = root.editorTree.first(where: { $0.document.index(ofBlock: blockId) != nil }) else { return false }
        let moved = movedIds(of: blockId, in: root)
        switch target {
        case .besideRight(let targetId):
            return source.placeBlocks(moved, besideRightOf: targetId)
        case .gap(let containerId, let index):
            guard let editor = root.editorTree.first(where: { $0.document.containerId == containerId }) else { return false }
            if editor === source {
                editor.window?.makeFirstResponder(editor)
                editor.moveBlock(blockId, toGap: index)
                return true
            }
            let blocks = editor.document.blocks
            source.moveBlocks(moved, to: containerId, after: index > 0 ? blocks[index - 1].id : nil,
                              before: index < blocks.count ? blocks[index].id : nil)
            return true
        }
    }

    /// Блок и его вложенные в его потоке.
    static func movedIds(of blockId: UUID, in root: PageTextView) -> [UUID] {
        guard let source = root.editorTree.first(where: { $0.document.index(ofBlock: blockId) != nil }),
              let index = source.document.index(ofBlock: blockId) else { return [blockId] }
        let blocks = source.document.blocks
        return blocks[index..<BlockMoveController.subtreeEnd(blocks, of: index)].map(\.id)
    }
}

extension PageTextView {
    func dropTarget(forBlock blockId: UUID, atWindowPoint point: NSPoint) -> BlockDropTarget? {
        FlowDragCoordinator.dropTarget(forBlock: blockId, atWindowPoint: point, in: pageEditor)
    }

    @discardableResult
    func dropBlock(_ blockId: UUID, atWindowPoint point: NSPoint) -> Bool {
        FlowDragCoordinator.drop(blockId, atWindowPoint: point, in: pageEditor)
    }

    /// Абзац блока `index` в координатах этого редактора: по высоте — его фрагмент раскладки, по ширине — колонка текста.
    func blockFrame(ofBlockAt index: Int) -> NSRect? {
        guard document.blocks.indices.contains(index), let textLayoutManager, let storage = textContentStorage,
              let location = storage.location(storage.documentRange.location, offsetBy: mapper.paragraphStart(ofBlockAt: index)) else { return nil }
        textLayoutManager.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = textLayoutManager.textLayoutFragment(for: location) else { return nil }
        var frame = fragment.layoutFragmentFrame
        let lines = fragment.textLineFragments
        if let extra = lines.last, extra.characterRange.length == 0, lines.count > 1 {
            frame.size.height = extra.typographicBounds.minY
        }
        let origin = textContainerOrigin
        let width = textContainer?.size.width ?? frame.width
        return NSRect(x: origin.x, y: origin.y + frame.minY, width: width, height: frame.height)
    }

    /// Рамка блока любого потока страницы в координатах окна; его редактора нет на экране — `nil`.
    func frameInWindow(ofBlock id: UUID) -> NSRect? {
        for editor in pageEditor.editorTree {
            guard let index = editor.document.index(ofBlock: id), let frame = editor.blockFrame(ofBlockAt: index) else { continue }
            return editor.convert(frame, to: nil)
        }
        return nil
    }
}
