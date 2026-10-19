import AppKit
import NotesCore

/// Абзацы, спрятанные от раскладки (research R1, проба T003): текст страницы не меняется — TextKit 2 просто
/// не получает их при перечислении элементов (`textContentManager(_:shouldEnumerate:options:)`), и у них нет строк.
/// Записи отмены `NSTextView` ссылаются на места в тексте, а места не сдвигаются: ⌘Z не задет.
/// Какие блоки прятать (дети свёрнутых переключателей), решает `Collapsing`; здесь — только само скрытие.
@MainActor
final class HiddenParagraphs: NSObject, NSTextContentStorageDelegate {
    weak var textView: PageTextView?
    /// Блоки, чьи абзацы не раскладываются.
    private(set) var hiddenBlockIds: Set<UUID> = []

    /// Спрятать ровно эти блоки; раскладка пересчитывается только у абзацев, чья видимость поменялась.
    func setHiddenBlocks(_ ids: Set<UUID>) {
        guard ids != hiddenBlockIds else { return }
        let changed = ids.symmetricDifference(hiddenBlockIds)
        hiddenBlockIds = ids
        relayout(changed)
    }

    func isHidden(_ blockId: UUID) -> Bool { hiddenBlockIds.contains(blockId) }

    nonisolated func textContentManager(_ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
                                        options: NSTextContentManager.EnumerationOptions) -> Bool {
        // TextKit перечисляет элементы на главном потоке, как и рисует фрагменты (`BlockLayoutFragment`).
        nonisolated(unsafe) let element = textElement
        return MainActor.assumeIsolated {
            guard !hiddenBlockIds.isEmpty, let paragraph = element as? NSTextParagraph,
                  paragraph.attributedString.length > 0,
                  let id = paragraph.attributedString.attribute(.blockID, at: 0, effectiveRange: nil) as? UUID else { return true }
            return !hiddenBlockIds.contains(id)
        }
    }

    /// Переложить абзацы от первого блока с новой видимостью до конца страницы: уже разложенные абзацы ниже
    /// сами не сдвигаются, если их раскладку не сбросить (проба T003).
    private func relayout(_ changed: Set<UUID>) {
        guard let textView, let layoutManager = textView.textLayoutManager, let storage = textView.textContentStorage else { return }
        guard let first = changed.compactMap(textView.document.index(ofBlock:)).min(),
              let start = storage.location(storage.documentRange.location, offsetBy: textView.mapper.paragraphStart(ofBlockAt: first)),
              let range = NSTextRange(location: start, end: storage.documentRange.endLocation) else { return }
        layoutManager.invalidateLayout(for: range)
        if textView.window != nil { layoutManager.textViewportLayoutController.layoutViewport() }
        textView.needsDisplay = true
    }
}

extension PageTextView {
    /// Спрятать от раскладки абзацы ровно этих блоков (дети свёрнутых переключателей, research R1).
    public func setHiddenBlocks(_ ids: Set<UUID>) {
        hiddenParagraphs.setHiddenBlocks(ids)
    }
}
