import CoreGraphics
import Testing
import UIGallery

/// Цель снимка в окне (ui-review 2026-10-15-round2, №25): галерея прокручивает страницу к цели,
/// а цель за краем окна делает состояние не снятым.
@Suite("Цель снимка в видимой части окна")
struct GalleryViewportTests {
    @Test("Прокрутка ставит цель посередине видимой высоты")
    func centersTarget() {
        let target = CGRect(x: 0, y: 1500, width: 600, height: 30)
        #expect(GalleryViewport.scrollOffset(centering: target, visibleHeight: 800, documentHeight: 3000) == 1115)
    }

    @Test("Прокрутка не выходит за начало и конец документа")
    func clampsToDocument() {
        #expect(GalleryViewport.scrollOffset(centering: CGRect(x: 0, y: 100, width: 10, height: 20),
                                             visibleHeight: 800, documentHeight: 3000) == 0)
        #expect(GalleryViewport.scrollOffset(centering: CGRect(x: 0, y: 2950, width: 10, height: 20),
                                             visibleHeight: 800, documentHeight: 3000) == 2200)
        #expect(GalleryViewport.scrollOffset(centering: CGRect(x: 0, y: 300, width: 10, height: 20),
                                             visibleHeight: 800, documentHeight: 500) == 0, "Документ короче окна")
    }

    @Test("Цель целиком в видимой части — снимать можно")
    func visibleTargetHasNoProblem() {
        let visible = CGRect(x: 271, y: 0, width: 1169, height: 820)
        #expect(GalleryViewport.problem("ручки блока", at: CGRect(x: 400, y: 300, width: 44, height: 24), visible: visible) == nil)
        #expect(GalleryViewport.problem("ручки блока", at: CGRect(x: 271, y: 0, width: 44, height: 24), visible: visible) == nil,
                "Вплотную к краю — ещё в окне")
    }

    @Test("Цель за краем окна или не найдена — состояние не снято, причина называет цель")
    func hiddenTargetIsAProblem() throws {
        let visible = CGRect(x: 271, y: 0, width: 1169, height: 820)
        let below = try #require(GalleryViewport.problem("ручки блока checkbox", at: CGRect(x: 400, y: -33, width: 44, height: 24),
                                                        visible: visible))
        #expect(below.hasPrefix("цель вне окна: ручки блока checkbox"))
        #expect(GalleryViewport.problem("меню", at: CGRect(x: 400, y: 700, width: 200, height: 300), visible: visible) != nil,
                "Наполовину за краем — тоже вне окна")
        #expect(GalleryViewport.problem("курсор", at: nil, visible: visible) == "цель не найдена: курсор")
    }
}
