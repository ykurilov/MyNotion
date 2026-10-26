import AppKit
import NotesCore

extension PageTextView {
    /// Щелчок ниже последнего блока, как в Notion: курсор встаёт в пустой абзац в конце страницы.
    /// Если последний блок — не пустой абзац, такой абзац добавляется (⌘Z его убирает).
    func placeCaretInTrailingParagraph() {
        commitEdits()
        closePopups()
        if let last = document.blocks.last, last.kind == .paragraph, last.text.string.isEmpty {
            focusBody(at: mapper.paragraphStart(ofBlockAt: document.blocks.count - 1))
            return
        }
        insertEmptyBlock(at: document.blocks.count, openingSlashMenu: false)
    }

    /// Точка в пустом месте страницы под последним блоком (координаты окна текста).
    func isBelowLastBlock(_ point: NSPoint) -> Bool {
        guard point.y >= textContainerOrigin.y else { return false }
        guard !document.blocks.isEmpty else { return true }
        guard let line = markerLine(ofBlockAt: document.blocks.count - 1) else { return false }
        return point.y > textContainerOrigin.y + line.top + line.height
    }
}
