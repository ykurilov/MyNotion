import AppKit
import Testing
@testable import NotesCore
@testable import PageCover
import VisualStyle

/// Вид обложки (contracts/pages-ui.md, «Шапка страницы»): картинка заполняет по ширине, видна часть по сдвигу;
/// кнопки при наведении у правого края колонки; «Переместить» тянет картинку и сохраняет сдвиг одной правкой.
@MainActor
@Suite("Обложка: вид")
struct CoverViewTests {
    @Test("Картинка заполняет по ширине; сдвиг 0 — верх, 1 — низ; низкая картинка — по высоте, по центру")
    func placement() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 250)
        #expect(CoverImagePlacement.rect(imageAspect: 1, in: bounds, offset: 0) == CGRect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(CoverImagePlacement.rect(imageAspect: 1, in: bounds, offset: 1) == CGRect(x: 0, y: -750, width: 1000, height: 1000))
        #expect(CoverImagePlacement.rect(imageAspect: 1, in: bounds, offset: 0.5).minY == -375)
        #expect(CoverImagePlacement.rect(imageAspect: 8, in: bounds, offset: 0.5) == CGRect(x: -500, y: 0, width: 2000, height: 250))
    }

    @Test("«Переместить»: тянут вниз — видно выше (сдвиг меньше), не выходит за 0…1")
    func repositionDrag() {
        var mode = CoverRepositionMode(offset: 0.5)
        mode.beginDrag(atY: 100)
        mode.drag(toY: 175, spare: 750)
        #expect(mode.offset == 0.4)
        mode.drag(toY: 10_000, spare: 750)
        #expect(mode.offset == 0)
        mode.endDrag()
        mode.beginDrag(atY: 0)
        mode.drag(toY: -10_000, spare: 750)
        #expect(mode.offset == 1)
        #expect(mode.originalOffset == 0.5)
    }

    @Test("Кнопки «Сменить обложку» и «Переместить» — при наведении, у правого края колонки, у низа обложки")
    func hoverButtons() {
        let view = CoverView(cover: PageCover(source: .gallery("gradients_3")), fileURL: { _ in nil })
        view.frame = NSRect(x: 0, y: 0, width: 1200, height: 230)
        view.setColumn(left: 240, width: 720)
        view.layoutSubtreeIfNeeded()
        #expect(view.buttons.isHidden)
        view.isHovered = true
        view.layoutSubtreeIfNeeded()
        #expect(!view.buttons.isHidden)
        #expect(view.buttons.items.map(\.title) == ["Сменить обложку", "Переместить"])
        #expect(view.buttons.frame.maxX == 960)
        #expect(view.buttons.frame.maxY == 230 - Metrics.PageCover.buttonBottomInset)
        #expect(view.image != nil)
    }

    @Test("«Переместить» → протянуть → «Сохранить положение» — один сдвиг хозяину; «Отмена» — ничего")
    func repositionSaveAndCancel() {
        let view = CoverView(cover: PageCover(source: .gallery("gradients_3")), fileURL: { _ in nil })
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 250)
        var saved: [Double] = []
        view.onSaveOffset = { saved.append($0) }

        view.repositionButton.press()
        #expect(view.buttons.items.map(\.title) == ["Сохранить положение", "Отмена"])
        #expect(!view.repositionHint.isHidden)
        #expect(!view.buttons.isHidden)
        view.drag(by: 150)
        view.cancelButton.press()
        #expect(saved.isEmpty)
        #expect(view.cover.offset == 0.5)

        view.repositionButton.press()
        view.drag(by: 150)
        view.saveButton.press()
        #expect(saved == [0.3])
        #expect(view.repositionHint.isHidden)
    }

    @Test("Файла ещё нет — заглушка; неизвестный id галереи — заглушка")
    func placeholder() {
        let ref = AttachmentRef(name: "далеко.png", byteCount: 1, contentType: "public.png", sha256: "")
        let file = CoverView(cover: PageCover(source: .file(ref)), fileURL: { _ in nil })
        #expect(file.image == nil)
        let unknown = CoverView(cover: PageCover(source: .gallery("gradients_99")), fileURL: { _ in nil })
        #expect(unknown.image == nil)
    }

    @Test("Окно «Сменить обложку»: вкладки, «Убрать», плитки галереи по порядку; выбор плитки сообщается")
    func picker() {
        let view = CoverPickerView(tab: .gallery)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        var chosen: [CoverPickerController.Choice] = []
        view.onChoose = { chosen.append($0) }
        #expect(view.tiles.map(\.item.id) == CoverGallery.ids)
        #expect(view.tiles[1].frame.minX > view.tiles[0].frame.maxX)
        #expect(view.tiles[4].frame.minY > view.tiles[0].frame.maxY)
        #expect(view.galleryTab.isSelected)
        view.tiles[2].press()
        view.removeButton.press()
        #expect(chosen == [.gallery("solid_blue"), .remove])
        view.uploadTab.press()
        #expect(view.uploadTab.isSelected)
        #expect(!view.uploadButton.isHidden)
        #expect(view.tiles.allSatisfy { $0.isHidden })
    }
}
