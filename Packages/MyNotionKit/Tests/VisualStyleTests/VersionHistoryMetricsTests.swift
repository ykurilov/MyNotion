import CoreGraphics
import Testing
@testable import VisualStyle

/// Панель «История версий» как у Notion 7.39 (замер 21.10.2026; T101 № 4, 16).
@Suite("Геометрия истории версий")
struct VersionHistoryMetricsTests {
    @Test("Панель шире боковой, как у Notion (320 при 270): «✎» строки светофора стоит внутри неё с полем не меньше 8")
    func panelHoldsToolbarButtons() {
        #expect(Metrics.VersionHistory.panelWidth == 320)
        #expect(abs(Metrics.VersionHistory.panelWidth / Metrics.Sidebar.defaultWidth - 320.0 / 270.0) < 0.01)
        // «✎» — у правого края боковой панели по умолчанию.
        let newPageButtonMaxX = Metrics.Sidebar.defaultWidth - Metrics.Sidebar.panelInset
        #expect(Metrics.VersionHistory.panelWidth - newPageButtonMaxX >= 8)
    }

    @Test("Строка времени справа 64, «Группировать» 20 с полями 6, список 180 на 6 ниже кнопки")
    func headerLikeNotion() {
        #expect(Metrics.VersionHistory.previewHeaderHeight == 64)
        #expect(Metrics.VersionHistory.groupingHeight == 20 && Metrics.VersionHistory.groupingPadding == 6)
        #expect(Metrics.VersionHistory.groupingMenuWidth == 180 && Metrics.VersionHistory.groupingMenuGap == 6)
        #expect(Metrics.VersionHistory.rowHeight == 64 && Metrics.VersionHistory.listInset == 12)
    }
}
