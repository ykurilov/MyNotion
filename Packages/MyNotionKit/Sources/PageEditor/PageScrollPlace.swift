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

    /// Редактор показывает страницу `pageId`: только тогда `current()` — её место (прошлый редактор ещё может быть жив).
    public func showsEditor(of pageId: UUID) -> Bool {
        textView?.document.pageId == pageId
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
    /// поэтому после первой прокрутки место уточняется по разложенному абзацу, а потом держится якорем
    /// (`keepScrollAnchor`). Курсор — в начало блока, без прокрутки.
    func restoreScrollPlace(_ place: TabScroll) {
        guard let index = document.index(ofBlock: place.blockId), let scrollView = enclosingScrollView,
              let layoutManager = textLayoutManager, let storage = textContentStorage else { return }
        let start = mapper.paragraphStart(ofBlockAt: index)
        guard let location = storage.location(storage.documentRange.location, offsetBy: start) else { return }
        let clip = scrollView.contentView
        let top = layoutManager.textViewportLayoutController.relocateViewport(to: location) + textContainerOrigin.y
        blockViews.withoutUpdatesOnScroll {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, top + place.offset)))
            scrollView.reflectScrolledClipView(clip)
        }
        scrollAnchor = ScrollAnchor(blockId: place.blockId, offset: place.offset, visibleTop: clip.bounds.minY)
        layoutSubtreeIfNeeded()
        keepScrollAnchor()
        setSelectedRange(NSRange(location: start, length: 0))
    }

    /// Держать блок якоря на его месте у верха видимой области. Уже после возврата места — в первой отрисовке
    /// и позже — раскладка запаса над видимой областью (виды блоков, `BlockViewHosting`) сменяет оценки высот
    /// TextKit 2 точными, а виды колонок и таблиц узнают свою высоту: без якоря блок съезжал вниз на 100–400 точек
    /// (замер вкладок: 16 возвратов из 100). Зовётся после каждой раскладки. Якорь отпускается, когда страницу прокрутил кто-то другой (человек,
    /// поиск, переход к блоку) или в ней правят текст.
    func keepScrollAnchor() {
        guard let anchor = scrollAnchor, !isKeepingScrollAnchor, let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        guard abs(clip.bounds.minY - anchor.visibleTop) < 0.5, let index = document.index(ofBlock: anchor.blockId) else {
            scrollAnchor = nil
            return
        }
        isKeepingScrollAnchor = true
        defer { isKeepingScrollAnchor = false }
        // Прокрутка ставит виды на новые абзацы, и их высоты могут сдвинуть блок ещё раз.
        for _ in 0..<4 {
            guard let blockTop = paragraphTop(ofBlockAt: index) else { break }
            let wanted = max(0, blockTop + anchor.offset)
            guard abs(wanted - clip.bounds.minY) > 0.5 else { break }
            blockViews.withoutUpdatesOnScroll {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: wanted))
                scrollView.reflectScrolledClipView(clip)
            }
            // Якорь держится и посреди раскладки окна: раскладка видимой области — напрямую, не через `layout()`.
            textLayoutManager?.textViewportLayoutController.layoutViewport()
            blockViews.update()
        }
        scrollAnchor?.visibleTop = clip.bounds.minY
    }

    /// Верх абзаца блока в координатах текста по разложенному фрагменту; `nil` — абзац не разложен.
    func paragraphTop(ofBlockAt index: Int) -> CGFloat? {
        guard let layoutManager = textLayoutManager, let storage = textContentStorage,
              let location = storage.location(storage.documentRange.location, offsetBy: mapper.paragraphStart(ofBlockAt: index)),
              let fragment = layoutManager.textLayoutFragment(for: location) else { return nil }
        return fragment.layoutFragmentFrame.minY + textContainerOrigin.y
    }
}

/// Блок, который держится у верха видимой области после возврата места: `offset` — сдвиг верха области от верха
/// его абзаца, `visibleTop` — где якорь сам поставил область в последний раз.
struct ScrollAnchor {
    let blockId: UUID
    let offset: CGFloat
    var visibleTop: CGFloat
}
