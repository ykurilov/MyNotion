import AppKit
import NotesCore

/// Строки шаблонов на пустой странице (US7). Виды создаются, только если страница пуста и шаблоны есть, —
/// открытие обычной страницы они не утяжеляют.
extension PageTextView {
    /// Страница пуста: один пустой абзац и ничего больше; сама страница не шаблон.
    private var offersTemplates: Bool {
        showsPageHeader && !templateChoices.isEmpty && !document.page.isTemplate
            && document.blocks.count == 1 && document.blocks[0].kind == .paragraph && (textStorage?.string ?? "\n") == "\n"
    }

    func updateTemplateRows() {
        guard offersTemplates, let line = markerLine(ofBlockAt: 0) else {
            templateRows?.hide()
            return
        }
        let controller = templateRows ?? TemplateRowsController(textView: self)
        templateRows = controller
        let origin = textContainerOrigin
        let left = line.caretX + origin.x - Self.hintLabelTextInset
        controller.show(templateChoices, left: left, top: line.top + line.height + origin.y,
                        width: max(160, column.left + column.width - left))
    }

    func chooseTemplate(_ templateId: UUID) {
        templateRows?.hide()
        onChooseTemplate?(templateId)
    }

    func handleTemplateRowsCommand(_ selector: Selector) -> Bool {
        window?.firstResponder === self && templateRows?.handle(selector) == true
    }
}
