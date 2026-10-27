import AppKit
import NotesCore

/// Вставка текста другой программы блоками (Markdown ответа ИИ): блоки даёт `pastedTextReader`, редактор ставит их
/// на место курсора, как Notion. Первый блок вставки сливается с текстом до курсора, последний — с текстом после;
/// остальные встают целиком. Вся вставка — один шаг ⌘Z.
extension PageTextView {
    /// Блоки из простого текста и HTML буфера; `nil` — вставлять текстом в строку. Блоки потока страницы —
    /// без `containerId`, содержимое таблиц и колонок — с id своего контейнера из этого же списка; страница — `pageId`.
    /// `webCustomData` — буфер Chromium (`org.chromium.web-custom-data`): Notion кладёт в него места пустых блоков.
    public typealias PastedTextReader = @MainActor (_ text: String, _ html: String?, _ pageId: UUID, _ hasRichText: Bool,
                                                    _ webCustomData: Data?) -> [Block]?

    /// `false` — ставить блоки здесь нельзя (курсор у блока без текста): вставка идёт текстом. `keepsLook` — блоки
    /// скопированы в MyNotion: первый в пустое начало встаёт целиком, с отметкой, цветом и свойствами.
    func pasteBlocks(_ pasted: [Block], replacing selection: NSRange, keepsLook: Bool = false) -> Bool {
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
            if head.string.isEmpty, keepsLook, flow[0].kind != .paragraph || first.kind == .paragraph {
                merged.kind = flow[0].kind
                merged.isChecked = flow[0].isChecked
                merged.color = flow[0].color
                merged.props = flow[0].props
            } else if head.string.isEmpty, flow[0].kind != .paragraph {
                merged.isChecked = flow[0].isChecked
                if flow[0].kind != first.kind {
                    merged.kind = flow[0].kind
                    merged.adoptDefaults(of: flow[0].kind, from: first)
                }
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
        insertContents(of: pasted, origins: origins, at: start.index, fitsTablesToPage: !keepsLook)
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Вставить")

        let index = min(start.index + caret.item, document.blocks.count - 1)
        setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: index) + caret.offset, length: 0))
        scrollRangeToVisible(selectedRange())
        return true
    }

    /// Таблица из чужого Markdown или HTML ширин столбцов не знает (у разбора это обычные 120): как у Notion, её столбцы
    /// делят строку страницы поровну. Ширины, выставленные руками, остаются.
    private func fitColumnsToPage(of tableIds: Set<UUID>, in upserts: inout [Block]) {
        for tableId in tableIds {
            guard let table = document.block(tableId), table.kind == .table else { continue }
            let columns = upserts.indices.filter { upserts[$0].kind == .tableColumn && upserts[$0].containerId == tableId }
            let isUnset = columns.allSatisfy { (upserts[$0].props.width ?? TableGrid.defaultColumnWidth) == TableGrid.defaultColumnWidth }
            guard !columns.isEmpty, isUnset else { continue }
            let width = TableGrid.columnWidth(ofColumns: columns.count, sharing: availableTableWidth(indent: table.indent))
            for index in columns { upserts[index].props.width = width }
        }
    }

    /// Ячейки таблиц и блоки колонок вставки — в потоки своих новых контейнеров.
    private func insertContents(of pasted: [Block], origins: [UUID?], at startIndex: Int, fitsTablesToPage: Bool) {
        let contents = pasted.filter { $0.containerId != nil }
        guard !contents.isEmpty else { return }
        var newIds: [UUID: UUID] = [:]
        for (position, origin) in origins.enumerated() where startIndex + position < document.blocks.count {
            if let origin { newIds[origin] = document.blocks[startIndex + position].id }
        }
        var upserts = contents.map { block in
            var block = block
            if let containerId = block.containerId, let newId = newIds[containerId] { block.containerId = newId }
            return block
        }
        if fitsTablesToPage { fitColumnsToPage(of: Set(newIds.values), in: &upserts) }
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
