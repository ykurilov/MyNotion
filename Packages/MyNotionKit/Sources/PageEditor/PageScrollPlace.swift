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
    /// (`keepScrollAnchor`). Выделение — в начало блока, но курсор скрыт (`isCaretHiddenUntilUserAction`).
    func restoreScrollPlace(_ place: TabScroll) {
        guard let index = document.index(ofBlock: place.blockId) else { return }
        scroll(to: place)
        // Курсора на вернувшейся странице нет, пока человек сам не щёлкнет или не нажмёт клавишу.
        isCaretHiddenUntilUserAction = true
        setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: index), length: 0))
    }

    /// Поставить блок места у верха видимой области и держать его там якорем; выделение не трогается.
    func scroll(to place: TabScroll) {
        guard let index = document.index(ofBlock: place.blockId), let scrollView = enclosingScrollView,
              let layoutManager = textLayoutManager, let storage = textContentStorage else { return }
        let start = mapper.paragraphStart(ofBlockAt: index)
        guard let location = storage.location(storage.documentRange.location, offsetBy: start) else { return }
        let clip = scrollView.contentView
        var top = layoutManager.textViewportLayoutController.relocateViewport(to: location) + textContainerOrigin.y
        // Блок в первых экранах: всё выше него — сразу точной раскладкой, а не оценкой. Иначе выше потом уточнялось уже
        // после раскладки видимой области, и абзацы под блоком оставались на старых местах: заголовок у верха области
        // возвращался на 20–70 точек ниже (замер вкладок: 2 возврата из 110). Раскладка с начала у начала страницы
        // недорогая — виды блоков (`BlockViewHosting`) делают её там всё равно.
        if top - textContainerOrigin.y < clip.bounds.height * 2,
           let end = storage.location(location, offsetBy: max(0, mapper.characterRange(ofBlocksAt: index..<index + 1).length)) {
            layoutManager.ensureLayout(for: NSTextRange(location: storage.documentRange.location, end: end) ?? storage.documentRange)
            top = paragraphTop(ofBlockAt: index) ?? top
        }
        blockViews.withoutUpdatesOnScroll {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, top + place.offset)))
            scrollView.reflectScrolledClipView(clip)
        }
        scrollAnchor = ScrollAnchor(blockId: place.blockId, offset: place.offset, visibleTop: clip.bounds.minY)
        layoutSubtreeIfNeeded()
        keepScrollAnchor()
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

    /// Раскладка видимой области, после которой TextKit 2 сам сдвигает прокрутку, уточнив высоты выше неё
    /// (`textViewportLayoutControllerDidLayout`). Это не чужая прокрутка: якорь принимает новое место, а потом ставит
    /// блок обратно. Иначе он отпускался посреди возврата места, когда колонки выше узнавали свою высоту (T085).
    func layoutKeepingScrollAnchor(_ layout: () -> Void) {
        guard let anchor = scrollAnchor, let clip = enclosingScrollView?.contentView,
              abs(clip.bounds.minY - anchor.visibleTop) < 0.5 else { return layout() }
        layout()
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
