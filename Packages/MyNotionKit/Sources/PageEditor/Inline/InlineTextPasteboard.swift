import AppKit
import NotesCore

/// Копирование внутри MyNotion с упоминаниями и датами: свой тип в буфере — `InlineText` одного блока в JSON.
/// Чужие программы берут простой текст (название страницы, дата словами) или RTF.
extension PageTextView {
    static let inlineTextPasteboardType = NSPasteboard.PasteboardType("ru.kurilov.mynotion.inline-text")

    func writeInlineText(to pboard: NSPasteboard) -> Bool {
        guard let textStorage else { return false }
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        // Несколько блоков — как раньше, через RTF: этот тип держит текст одного блока.
        let source = textStorage.string as NSString
        guard !ranges.isEmpty, ranges.allSatisfy({ source.substring(with: $0).contains("\n") == false }) else { return false }
        var string = ""
        var runs: [StyledRun] = []
        for (index, range) in ranges.enumerated() {
            if index > 0 { string += "\n" }
            let piece = PageTextStorageMapper.inlineText(in: textStorage, range: range.location..<NSMaxRange(range))
            let offset = (string as NSString).length
            runs += piece.runs.map { StyledRun(start: $0.start + offset, length: $0.length, style: $0.style) }
            string += piece.string
        }
        guard let data = try? JSONEncoder().encode(InlineText(string, runs: runs)) else { return false }
        return pboard.setData(data, forType: Self.inlineTextPasteboardType)
    }

    /// Вставка скопированного в MyNotion: оформление и атомы сохраняются, у каждой даты — новый id
    /// (новое напоминание, data-model.md). `false` — в буфере нет своего типа.
    func pasteInlineText(from pasteboard: NSPasteboard, replacing selection: NSRange) -> Bool {
        guard let data = pasteboard.data(forType: Self.inlineTextPasteboardType),
              let copied = try? JSONDecoder().decode(InlineText.self, from: data), !copied.string.isEmpty,
              let position = mapper.blockPosition(at: selection.location) else { return false }
        let block = document.blocks[position.index]
        let previous = mapper.previousKind(ofBlockAt: position.index)
        let rendered = PageTextStorageMapper.paragraph(Block(id: block.id, pageId: block.pageId, kind: block.kind, text: copied.withNewDateIds(),
                                                             indent: block.indent, isChecked: block.isChecked, sortKey: block.sortKey),
                                                       withNewline: false, after: previous)
        breakUndoCoalescing()
        replaceText(in: selection, with: rendered)
        setSelectedRange(NSRange(location: selection.location + rendered.length, length: 0))
        scrollRangeToVisible(selectedRange())
        return true
    }
}

extension InlineText {
    /// Тот же текст, но у каждой даты свой новый id.
    func withNewDateIds() -> InlineText {
        InlineText(string, runs: runs.map { run in
            guard case .date(var date) = run.style else { return run }
            date.id = .timeOrdered()
            return StyledRun(start: run.start, length: run.length, style: .date(date))
        })
    }
}
