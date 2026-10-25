import AppKit
import NotesCore

/// Вставка текста другой программы блоками (Markdown ответа ИИ): блоки даёт `pastedTextReader`, редактор ставит их
/// на место курсора, как Notion. Первый блок вставки сливается с текстом до курсора, последний — с текстом после;
/// остальные встают целиком. Вся вставка — один шаг ⌘Z.
extension PageTextView {
    /// Блоки из текста буфера; `nil` — вставлять текстом в строку. Блоки потока страницы — без `containerId`,
    /// содержимое таблиц и колонок — с id своего контейнера из этого же списка; страница — `pageId`.
    public typealias PastedTextReader = @MainActor (_ text: String, _ pageId: UUID, _ hasRichText: Bool) -> [Block]?

    /// `false` — ставить блоки здесь нельзя (курсор у блока без текста): вставка идёт текстом.
    func pasteBlocks(_ pasted: [Block], replacing selection: NSRange) -> Bool {
        let flow = pasted.filter { $0.containerId == nil }
        guard !flow.isEmpty, let start = mapper.blockPosition(at: selection.location),
              let end = mapper.blockPosition(at: NSMaxRange(selection)) else { return false }
        let blocks = document.blocks
        let first = blocks[start.index], last = blocks[end.index]
        guard first.kind.holdsPastedText, last.kind.holdsPastedText else { return false }
        let head = first.text.slice(0..<start.offset)
        let tail = last.text.slice(end.offset..<(last.text.string as NSString).length)

        var drafts = flow.map { block in
            var draft = BlockDraft(block)
            draft.id = nil
            draft.indent += first.indent
            return draft
        }
        // Какой блок вставки стал каким черновиком: по нему содержимое таблиц находит свой новый контейнер.
        var origins: [UUID?] = flow.map(\.id)
        if flow[0].kind.holdsPastedText {
            // Первый блок вставки — продолжение блока под курсором; в пустое начало встаёт со своим типом.
            var merged = BlockDraft(first)
            merged.text = head.appending(flow[0].text, separator: "")
            if head.string.isEmpty, flow[0].kind != .paragraph, flow[0].kind != first.kind {
                merged.kind = flow[0].kind
                merged.isChecked = flow[0].isChecked
                merged.adoptDefaults(of: flow[0].kind, from: first)
            }
            drafts[0] = merged
        } else if !head.string.isEmpty {
            var kept = BlockDraft(first)
            kept.text = head
            drafts.insert(kept, at: 0)
            origins.insert(nil, at: 0)
        }
        // Курсор — в конце вставленного: перед хвостом абзаца.
        let caret: (item: Int, offset: Int)
        if let lastDraft = drafts.last, lastDraft.kind.holdsPastedText {
            caret = (drafts.count - 1, (lastDraft.text.string as NSString).length)
            drafts[drafts.count - 1].text = lastDraft.text.appending(tail, separator: "")
        } else {
            // После кода или таблицы — абзац с хвостом; в конце страницы — пустой, чтобы писать дальше.
            // Курсор — в начало блока под вставкой.
            caret = (drafts.count, 0)
            if !tail.string.isEmpty || end.index == blocks.count - 1 {
                drafts.append(BlockDraft(id: nil, text: tail, indent: first.indent))
                origins.append(nil)
            }
        }

        let undoManager = undoManager
        undoManager?.beginUndoGrouping()
        changeBlocks(start.index..<end.index + 1, to: drafts, actionName: "Вставить")
        insertContents(of: pasted, origins: origins, at: start.index)
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Вставить")

        let index = min(start.index + caret.item, document.blocks.count - 1)
        setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: index) + caret.offset, length: 0))
        scrollRangeToVisible(selectedRange())
        return true
    }

    /// Ячейки таблиц и блоки колонок вставки — в потоки своих новых контейнеров.
    private func insertContents(of pasted: [Block], origins: [UUID?], at startIndex: Int) {
        let contents = pasted.filter { $0.containerId != nil }
        guard !contents.isEmpty else { return }
        var newIds: [UUID: UUID] = [:]
        for (position, origin) in origins.enumerated() where startIndex + position < document.blocks.count {
            if let origin { newIds[origin] = document.blocks[startIndex + position].id }
        }
        let upserts = contents.map { block in
            var block = block
            if let containerId = block.containerId, let newId = newIds[containerId] { block.containerId = newId }
            return block
        }
        applyStructuralChanges(BlockChanges(upserts: upserts), actionName: "Вставить")
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        blockViews.update()
    }
}

extension BlockKind {
    /// В абзац блока можно вставить текст: не код, не таблица, не картинка, не подстраница.
    var holdsPastedText: Bool { !rendersAsAttachment && self != .pageLink }
}

extension InlineText {
    /// Кусок текста в смещениях UTF-16 — с оформлением, которое на него попадает.
    func slice(_ range: Range<Int>) -> InlineText {
        let units = Array(string.utf16)
        let lower = max(0, min(range.lowerBound, units.count)), upper = max(lower, min(range.upperBound, units.count))
        let runs = runs.compactMap { run -> StyledRun? in
            let start = max(run.start, lower), end = min(run.start + run.length, upper)
            return start < end ? StyledRun(start: start - lower, length: end - start, style: run.style) : nil
        }
        return InlineText(String(decoding: units[lower..<upper], as: UTF16.self), runs: runs).normalized()
    }
}
