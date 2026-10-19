import AppKit
import NotesCore
import VisualStyle

extension PageTextView {
    /// Предки блока `index` — ближайшие блоки выше с меньшей вложенностью, от ближайшего к внешнему (research R1).
    func ancestorIndices(ofBlockAt index: Int) -> [Int] {
        let blocks = document.blocks
        guard blocks.indices.contains(index) else { return [] }
        var level = blocks[index].indent
        var result: [Int] = []
        var current = index
        while level > 0, current > 0 {
            current -= 1
            if blocks[current].indent < level {
                result.append(current)
                level = blocks[current].indent
            }
        }
        return result
    }

    /// Последний видимый блок поддерева `index`: сам блок, если детей нет или они скрыты.
    func lastVisibleIndex(inSubtreeOf index: Int) -> Int {
        let end = BlockMoveController.subtreeEnd(document.blocks, of: index)
        var last = end - 1
        while last > index, hiddenParagraphs.isHidden(document.blocks[last].id) { last -= 1 }
        return last
    }

    /// Левый край блока на глубине `indent` в координатах контейнера.
    nonisolated static func blockLeft(atIndent indent: Int) -> CGFloat {
        CGFloat(indent) * Metrics.Page.indentPerLevel
    }
}

/// Кусок фигуры по поддереву (подложка выноски, черта цитаты) в абзаце одного блока: скругление — только у краёв фигуры.
enum SubtreePiece {
    static func path(_ rect: CGRect, roundsTop: Bool, roundsBottom: Bool, radius: CGFloat) -> NSBezierPath {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        let path = NSBezierPath()
        // Координаты перевёрнуты: верх фигуры — `minY`.
        let topRadius = roundsTop ? radius : 0
        let bottomRadius = roundsBottom ? radius : 0
        path.move(to: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        if topRadius > 0 {
            path.curve(to: CGPoint(x: rect.maxX, y: rect.minY + topRadius), controlPoint1: CGPoint(x: rect.maxX, y: rect.minY),
                       controlPoint2: CGPoint(x: rect.maxX, y: rect.minY))
        }
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius))
        if bottomRadius > 0 {
            path.curve(to: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY), controlPoint1: CGPoint(x: rect.maxX, y: rect.maxY),
                       controlPoint2: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.line(to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY))
        if bottomRadius > 0 {
            path.curve(to: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius), controlPoint1: CGPoint(x: rect.minX, y: rect.maxY),
                       controlPoint2: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
        if topRadius > 0 {
            path.curve(to: CGPoint(x: rect.minX + topRadius, y: rect.minY), controlPoint1: CGPoint(x: rect.minX, y: rect.minY),
                       controlPoint2: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.close()
        return path
    }
}
