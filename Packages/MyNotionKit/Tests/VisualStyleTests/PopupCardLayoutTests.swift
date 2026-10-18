import AppKit
import Testing
@testable import VisualStyle

/// Где встаёт всплывающая карточка (проверка интерфейса, раунд 4, № 13, 14).
@Suite("Место всплывающей карточки")
struct PopupCardLayoutTests {
    let window = NSRect(x: 0, y: 0, width: 1440, height: 900)

    @Test("Справа от строки панели: целиком правее края панели с зазором")
    func besidesSidebarRow() {
        let row = NSRect(x: 8, y: 10, width: 254, height: 30)
        let card = PopupCard.cardFrame(size: NSSize(width: 300, height: 160), anchor: row, in: window,
                                       gap: Metrics.Sidebar.panelInset + Metrics.TrashPanel.sidebarGap, preferringRight: true)
        #expect(card.minX >= 270 + 4, "\(card)")
        #expect(card.minY == row.minY)
    }

    @Test("Под меткой: зазор не меньше 8 до строки над карточкой, внутри окна")
    func belowLabel() {
        let label = NSRect(x: 1250, y: 500, width: 80, height: 20)
        let card = PopupCard.cardFrame(size: NSSize(width: 520, height: 240), anchor: label, in: window, gap: 8, preferringRight: false)
        #expect(label.minY - card.maxY >= 8)
        #expect(card.maxX <= window.maxX - 8 && card.minX >= 8)
    }
}
