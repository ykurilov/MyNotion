import Foundation
import NotesCore

/// Цвет блока в Markdown (FR-112; contracts/markdown-and-notion.md): строка `<!-- mynotion:color text=".." background=".." -->`
/// прямо перед блоком. Пишутся только отличия от цвета нового блока этого вида; сброшенное — словом `default`.
enum ColorWriter {
    static let marker = "mynotion:color"

    static func commentLine(for block: Block) -> String? {
        let defaults = BlockColor.defaults(for: block.kind)
        guard block.color != defaults else { return nil }
        var attributes: [String] = []
        if block.color.text != defaults.text { attributes.append("text=\"\(block.color.text?.rawValue ?? "default")\"") }
        if block.color.background != defaults.background {
            attributes.append("background=\"\(block.color.background?.rawValue ?? "default")\"")
        }
        return "<!-- \(marker) \(attributes.joined(separator: " ")) -->"
    }
}
