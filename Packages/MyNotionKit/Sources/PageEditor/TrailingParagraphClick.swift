import AppKit
import NotesCore

extension PageTextView {
    /// Щелчок ниже последнего блока, как в Notion: курсор встаёт в пустой абзац в конце страницы.
    /// Если последний блок — не пустой абзац, такой абзац добавляется. Пока в нём ничего не вписали, он не отдельный
    /// шаг отмены: ⌘Z убирает его и сразу отменяет прежнее действие — иначе ⌘Z после щелчка в страницу «не работал бы».
    /// Поле правки ячейки блоков не добавляет: в его потоке всегда один блок.
    func placeCaretInTrailingParagraph() {
        guard allowsBlockStructure else { return }
        commitEdits()
        closePopups()
        if let last = document.blocks.last, last.kind == .paragraph, last.text.string.isEmpty {
            focusBody(at: mapper.paragraphStart(ofBlockAt: document.blocks.count - 1))
            return
        }
        insertEmptyBlock(at: document.blocks.count, openingSlashMenu: false)
        untouchedClickedParagraph = document.blocks.last?.id
    }

    /// Точка в пустом месте страницы под последним блоком (координаты окна текста).
    func isBelowLastBlock(_ point: NSPoint) -> Bool {
        guard allowsBlockStructure, point.y >= textContainerOrigin.y else { return false }
        guard !document.blocks.isEmpty else { return true }
        guard let line = markerLine(ofBlockAt: document.blocks.count - 1) else { return false }
        return point.y > textContainerOrigin.y + line.top + line.height
    }
}
