import AppKit
import CodeHighlighting
import NotesCore

extension BlockKindDescriptor {
    /// Блок кода (US4, FR-104): абзац-вложение со своим редактором (`CodeBlockEditor.swift`), подсветка 24 языков.
    static let code = BlockKindDescriptor(
        kind: .code,
        menuItem: PopupMenuItem(title: "Код", icon: .symbol("chevron.left.forwardslash.chevron.right"),
                                keywords: ["code", "код", "программа", "```"], action: .setKind(.code)),
        markdownShortcuts: ["```"],
        gallerySamples: [
            BlockGallerySample(id: "code-swift", summary: "Код Swift с подсветкой между абзацами, пустой блок кода",
                               blocks: [
                                   .init(.paragraph, "Абзац над кодом"),
                                   .init(.code, """
                                       import Foundation

                                       /// Площадь круга.
                                       func area(of radius: Double) -> Double {
                                           let pi = 3.14159 // число пи
                                           return pi * radius * radius
                                       }
                                       print("Площадь: \\(area(of: 2))", true)
                                       """, props: BlockProps(["language": .string("swift")])),
                                   .init(.paragraph, "Абзац под кодом"),
                                   .init(.code, props: BlockProps(["language": .string("plain")])),
                               ], narrowToo: true),
            BlockGallerySample(id: "code-languages", summary: "Python, JSON, Bash, длинная строка с прокруткой вбок",
                               blocks: [
                                   .init(.code, "def greet(name):\n    # приветствие\n    return f\"Привет, {name}!\" if name else None",
                                         props: BlockProps(["language": .string("python")])),
                                   .init(.code, "{\n  \"name\": \"MyNotion\",\n  \"version\": 2,\n  \"sync\": true\n}",
                                         props: BlockProps(["language": .string("json")])),
                                   .init(.code, "for f in *.md; do echo \"$f\"; done  # очень длинная строка, которая не помещается в ширину колонки и прокручивается вбок",
                                         props: BlockProps(["language": .string("bash")])),
                               ]),
        ],
        // Богатая страница (quickstart.md): 5 блоков кода по 20 строк на разных языках.
        richPageBlocks: ["swift", "python", "javascript", "sql", "json"].enumerated().map { number, language in
            RichBlockSpec(.code, (0..<20).map { "line\(number)_\($0) = \($0) // строка \($0)" }.joined(separator: "\n"),
                          props: BlockProps(["language": .string(language)]))
        }
    )
}

extension PageTextView {
    // MARK: Создание

    /// Перед курсором в пустом до этого абзаце ровно «``»: третья «`» делает блок кода.
    var isCaretAfterTwoBackticks: Bool {
        let selection = selectedRange()
        guard selection.length == 0, let position = mapper.blockPosition(at: selection.location), position.offset == 2 else { return false }
        let block = document.blocks[position.index]
        return block.kind == .paragraph && block.text.string == "``"
    }

    /// «```» сразу после третьей «`» (contracts/blocks-and-keys.md, «Быстрые символы»): абзац становится кодом,
    /// курсор — в его редактор.
    func convertBackticksToCode() {
        commitEdits()
        let selection = selectedRange()
        guard let position = mapper.blockPosition(at: selection.location) else { return }
        breakUndoCoalescing()
        guard replaceText(in: NSRange(location: selection.location - position.offset, length: position.offset), with: "") else { return }
        insertCode(at: position.index)
    }

    /// Блок `index` становится кодом с последним выбранным языком; текст абзаца — код. Курсор — в конец кода.
    func insertCode(at index: Int) {
        commitEdits()
        let block = document.blocks[index]
        var draft = BlockDraft(block)
        draft.kind = .code
        draft.isChecked = false
        draft.adoptDefaults(of: .code, from: block)
        draft.props?.language = CodeLanguageMemory.last
        changeBlocks(index..<index + 1, to: [draft], actionName: "Код")
        focusCode(ofBlock: block.id, at: .end)
    }

    // MARK: Курсор между страницей и кодом

    /// Отдать курсор редактору кода блока. Вида ещё нет (строка не разложена) — прокрутить к ней, и вид возьмёт курсор,
    /// когда появится.
    func focusCode(ofBlock id: UUID, at caret: CodeCaret) {
        if let view = codeBlocks.view(for: id), view.window != nil {
            view.focus(caret)
            return
        }
        codeBlocks.pendingFocus = (id, caret)
        guard let index = document.index(ofBlock: id) else { return }
        scrollRangeToVisible(NSRange(location: mapper.paragraphStart(ofBlockAt: index), length: 1))
        if window != nil { textLayoutManager?.textViewportLayoutController.layoutViewport() }
        if let view = codeBlocks.view(for: id), view.window != nil, codeBlocks.pendingFocus?.blockId == id {
            codeBlocks.pendingFocus = nil
            view.focus(caret)
        }
    }

    enum CodeExit { case up, down }

    /// Курсор уходит из кода стрелкой: вверх — в конец блока над кодом, вниз — в начало блока под ним.
    /// Под кодом ничего нет — новый абзац, иначе из последнего блока страницы не выйти.
    func leaveCode(_ id: UUID, direction: CodeExit) {
        guard let index = document.index(ofBlock: id) else { return }
        switch direction {
        case .up:
            guard index > 0 else { return }
            focusPage(atBlock: index - 1, atEnd: true)
        case .down:
            guard index + 1 < document.blocks.count else { return insertParagraph(belowCode: id) }
            focusPage(atBlock: index + 1, atEnd: false)
        }
    }

    /// Курсор в начало или конец блока страницы; блок — тоже код: в его редактор.
    private func focusPage(atBlock index: Int, atEnd: Bool) {
        let block = document.blocks[index]
        if block.kind == .code { return focusCode(ofBlock: block.id, at: atEnd ? .end : .start) }
        window?.makeFirstResponder(self)
        let start = mapper.paragraphStart(ofBlockAt: index)
        setSelectedRange(NSRange(location: atEnd ? start + block.pageTextLength : start, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// ⌘Enter в коде и ↓ в последнем блоке страницы: новый абзац под кодом, курсор — в него.
    func insertParagraph(belowCode id: UUID) {
        guard let index = document.index(ofBlock: id) else { return }
        let block = document.blocks[index]
        changeBlocks(index..<index + 1, to: [BlockDraft(block), BlockDraft(id: nil, kind: .paragraph, indent: block.indent)],
                     actionName: "Новый абзац")
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: index + 1), length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// ⌫ в начале пустого кода — пустой абзац с курсором.
    func convertEmptyCodeToParagraph(_ id: UUID) {
        guard let index = document.index(ofBlock: id) else { return }
        var draft = BlockDraft(document.blocks[index])
        draft.kind = .paragraph
        draft.text = .empty
        changeBlocks(index..<index + 1, to: [draft], actionName: "Тип блока")
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: index), length: 0))
    }

    /// Стрелка на странице перешагнула бы блок кода (курсор внутрь вложения не встаёт): вместо этого курсор
    /// уходит в редактор кода — ↓ и → в начало, ↑ и ← в конец. `true` — стрелка обработана.
    func handleArrowIntoCode(_ selector: Selector) -> Bool {
        let forward: Bool
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveRight(_:)): forward = true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveLeft(_:)): forward = false
        default: return false
        }
        let before = selectedRange()
        guard before.length == 0, !isBlockSelection, let position = mapper.blockPosition(at: before.location) else { return false }
        let neighbor = position.index + (forward ? 1 : -1)
        guard neighbor >= 0, neighbor < document.blocks.count, document.blocks[neighbor].kind == .code else { return false }
        let id = document.blocks[neighbor].id
        super.doCommand(by: selector)
        // Курсор остался в своём блоке (не на краю строки) — стрелка в код не вела.
        guard let after = mapper.blockPosition(at: selectedRange().location), after.index != position.index else { return true }
        setSelectedRange(before)
        focusCode(ofBlock: id, at: forward ? .start : .end)
        return true
    }

    // MARK: Код в документ

    /// Код блока поправлен в его редакторе: в документ сразу, в отмену — шагом на серию набора (как у текста страницы).
    func codeTextDidChange(ofBlock id: UUID, from old: String, to new: String, kind: CodeEditKind) {
        writeCode(new, ofBlock: id)
        let continues = kind != .other && codeBlocks.typing.map { $0.blockId == id && $0.kind == kind } == true
        codeBlocks.typing = kind == .other ? nil : (id, kind)
        guard !continues else { return }
        registerCodeUndo(restoring: old, ofBlock: id)
    }

    private func registerCodeUndo(restoring text: String, ofBlock id: UUID) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { textView in textView.restoreCode(text, ofBlock: id) }
        undoManager.setActionName("Правка кода")
    }

    /// ⌘Z и ⇧⌘Z правки кода: текст — в документ и в вид, если он на экране; обратный шаг — в отмену.
    private func restoreCode(_ text: String, ofBlock id: UUID) {
        guard let current = document.block(id)?.text.string else { return }
        codeBlocks.breakTyping()
        writeCode(text, ofBlock: id)
        codeBlocks.view(for: id)?.showText(text)
        registerCodeUndo(restoring: current, ofBlock: id)
    }

    /// Записать код в документ; вложение блока на странице узнаёт новый текст, а при смене числа строк — и высоту.
    private func writeCode(_ text: String, ofBlock id: UUID) {
        guard let block = document.block(id), let position = document.index(ofBlock: id) else { return }
        let flow = document.blocks
        var draft = BlockDraft(block)
        draft.text = InlineText(text)
        document.replaceBlocks(after: position > 0 ? flow[position - 1].id : nil,
                               before: position + 1 < flow.count ? flow[position + 1].id : nil, with: [draft], origin: textStorage)
        guard let updated = document.block(id), let attachment = blockAttachment(ofBlock: id) else { return }
        let heightChanged = CodeBlockStyle.height(of: attachment.block.text.string) != CodeBlockStyle.height(of: text)
        attachment.update(updated)
        if heightChanged { invalidateAttachmentLayout(ofBlock: id) }
    }

    /// Курсор ушёл из кода: атрибут текста абзаца-вложения — снова как в документе (по нему ⌘Z удалённого абзаца
    /// и копирование страницы возвращают код).
    func codeEditingDidEnd(ofBlock id: UUID) {
        codeBlocks.breakTyping()
        guard let block = document.block(id), let index = document.index(ofBlock: id), let textStorage else { return }
        let start = mapper.paragraphStart(ofBlockAt: index)
        guard start < textStorage.length,
              textStorage.attribute(.blockText, at: start, effectiveRange: nil) as? InlineText != block.text else { return }
        textStorage.addAttribute(.blockText, value: block.text, range: NSRange(location: start, length: min(2, textStorage.length - start)))
    }

    /// Сменить язык блока кода одной правкой для ⌘Z.
    func setCodeLanguage(_ language: String, ofBlock id: UUID) {
        guard let index = document.index(ofBlock: id) else { return }
        var draft = BlockDraft(document.blocks[index])
        var props = document.blocks[index].props
        guard props.language != language else { return }
        props.language = language
        draft.props = props
        changeBlocks(index..<index + 1, to: [draft], actionName: "Язык кода")
    }

    // MARK: Вложения

    /// Вложение блока без своего текста на странице.
    func blockAttachment(ofBlock id: UUID) -> BlockAttachment? {
        guard let index = document.index(ofBlock: id), let textStorage else { return nil }
        let start = mapper.paragraphStart(ofBlockAt: index)
        guard start < textStorage.length else { return nil }
        return textStorage.attribute(.attachment, at: start, effectiveRange: nil) as? BlockAttachment
    }

    /// Высота вида блока поменялась: переложить только его абзац (проба T005 — абзацы ниже сдвигаются сами).
    func invalidateAttachmentLayout(ofBlock id: UUID) {
        guard let index = document.index(ofBlock: id), let storage = textContentStorage, let layoutManager = textLayoutManager,
              let start = storage.location(storage.documentRange.location, offsetBy: mapper.paragraphStart(ofBlockAt: index)),
              let end = storage.location(start, offsetBy: 1), let range = NSTextRange(location: start, end: end) else { return }
        layoutManager.invalidateLayout(for: range)
        if window != nil { layoutKeepingScrollAnchor { layoutManager.textViewportLayoutController.layoutViewport() } }
    }
}
