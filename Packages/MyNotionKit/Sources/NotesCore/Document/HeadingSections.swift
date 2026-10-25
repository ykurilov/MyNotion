import Foundation

/// Раздел заголовка — что прячет свёрнутый заголовок, как toggle heading в Notion: блоки потока после него до заголовка
/// того же или более крупного уровня на той же глубине, до выхода из родителя (заголовок внутри переключателя) или до
/// конца потока. Вложенное в блоки раздела идёт вместе с ними.
public enum HeadingSections {
    /// Уровень заголовка: 1 — самый крупный; не заголовок — `nil`.
    public static func level(_ kind: BlockKind) -> Int? {
        switch kind {
        case .heading1: 1
        case .heading2: 2
        case .heading3: 3
        default: nil
        }
    }

    /// Конец раздела заголовка `index`: первый блок после раздела (или `blocks.count`).
    public static func sectionEnd(_ blocks: [Block], ofHeadingAt index: Int) -> Int {
        guard blocks.indices.contains(index), let level = level(blocks[index].kind) else { return index + 1 }
        let indent = blocks[index].indent
        var end = index + 1
        while end < blocks.count {
            let block = blocks[end]
            if block.indent < indent { break }
            if block.indent == indent, let other = Self.level(block.kind), other <= level { break }
            end += 1
        }
        return end
    }

    /// Сколько блоков раздела на глубине заголовка: вложенные в них не считаются.
    public static func foldedCount(_ blocks: [Block], ofHeadingAt index: Int) -> Int {
        let end = sectionEnd(blocks, ofHeadingAt: index)
        guard end > index + 1 else { return 0 }
        let indent = blocks[index].indent
        return blocks[(index + 1)..<end].count { $0.indent <= indent }
    }

    /// Подпись свёрнутого заголовка: «…1 блок», «…3 блока», «…5 блоков».
    public static func foldedLabel(count: Int) -> String {
        let lastTwo = count % 100, last = count % 10
        let noun = if (11...14).contains(lastTwo) { "блоков" }
            else if last == 1 { "блок" }
            else if (2...4).contains(last) { "блока" }
            else { "блоков" }
        return "…\(count) \(noun)"
    }
}
