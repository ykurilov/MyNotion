import AppKit
import NotesCore

/// Место прокрутки открытой страницы для вкладок и «назад/вперёд» (research R5, data-model.md, «Tab.scroll»):
/// блок у верха видимой области и сдвиг от верха его абзаца. Окно держит один объект; редактор открытой страницы
/// цепляется к нему, когда создаётся.
@MainActor
public final class PageScrollPlace {
    private weak var textView: PageTextView?

    public init() {}

    func attach(_ textView: PageTextView) {
        self.textView = textView
    }

    /// Где стоит открытая страница сейчас; `nil` — редактора нет или страница в самом верху.
    public func current() -> TabScroll? {
        textView?.scrollPlace()
    }
}

extension PageTextView {
    func scrollPlace() -> TabScroll? {
        guard let clip = enclosingScrollView?.contentView, clip.bounds.minY > 0, !document.blocks.isEmpty else { return nil }
        let top = clip.bounds.minY
        let location = characterIndexForInsertion(at: NSPoint(x: textContainerOrigin.x + 1, y: max(top, textContainerOrigin.y) + 1))
        guard let index = mapper.blockPosition(at: location)?.index, let blockTop = paragraphTop(ofBlockAt: index) else { return nil }
        return TabScroll(blockId: document.blocks[index].id, offset: top - blockTop)
    }

    /// Вернуть место: TextKit 2 ставит видимую область на абзац блока (`relocateViewport`) — раскладывается он
    /// и соседи, а не всё выше (проба вкладок, research R14: 1–2 мс). Высоты выше блока до раскладки — оценка,
    /// поэтому после первой прокрутки место уточняется по разложенному абзацу. Курсор — в начало блока, без прокрутки.
    func restoreScrollPlace(_ place: TabScroll) {
        guard let index = document.index(ofBlock: place.blockId), let scrollView = enclosingScrollView,
              let layoutManager = textLayoutManager, let storage = textContentStorage else { return }
        let start = mapper.paragraphStart(ofBlockAt: index)
        guard let location = storage.location(storage.documentRange.location, offsetBy: start) else { return }
        let clip = scrollView.contentView
        var top = layoutManager.textViewportLayoutController.relocateViewport(to: location) + textContainerOrigin.y
        for _ in 0..<3 {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, top + place.offset)))
            scrollView.reflectScrolledClipView(clip)
            layoutSubtreeIfNeeded()
            guard let laidOut = paragraphTop(ofBlockAt: index), abs(laidOut - top) > 0.5 else { break }
            top = laidOut
        }
        setSelectedRange(NSRange(location: start, length: 0))
    }

    /// Верх абзаца блока в координатах текста по разложенному фрагменту; `nil` — абзац не разложен.
    private func paragraphTop(ofBlockAt index: Int) -> CGFloat? {
        guard let layoutManager = textLayoutManager, let storage = textContentStorage,
              let location = storage.location(storage.documentRange.location, offsetBy: mapper.paragraphStart(ofBlockAt: index)),
              let fragment = layoutManager.textLayoutFragment(for: location) else { return nil }
        return fragment.layoutFragmentFrame.minY + textContainerOrigin.y
    }
}
