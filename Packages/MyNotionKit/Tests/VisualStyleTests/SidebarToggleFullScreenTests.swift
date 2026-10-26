import CoreGraphics
import Testing
@testable import VisualStyle

@Suite("Шторка панели во весь экран")
struct SidebarToggleFullScreenTests {
    @Test("В обычном окне шторка правее светофора, во весь экран — вровень с полем поиска")
    func centers() {
        #expect(Metrics.Window.sidebarToggleCenterX(isFullScreen: false) == 95)
        let searchLeft = Metrics.Sidebar.panelInset + Metrics.SearchField.extraHorizontalInset
        let fullScreen = Metrics.Window.sidebarToggleCenterX(isFullScreen: true)
        #expect(fullScreen - Metrics.Window.toolbarButtonSize / 2 == searchLeft)
    }

    @Test("Полоса вкладок при спрятанной панели начинается сразу за шторкой в обоих режимах")
    func tabsFollowToggle() {
        for isFullScreen in [false, true] {
            let toggleRight = Metrics.Window.sidebarToggleCenterX(isFullScreen: isFullScreen) + Metrics.Window.toolbarButtonSize / 2
            let leading = Metrics.Tabs.collapsedSidebarLeading(isFullScreen: isFullScreen)
            #expect(abs(leading - (toggleRight + 2)) < 0.001, "isFullScreen=\(isFullScreen)")
        }
        #expect(Metrics.Tabs.collapsedSidebarLeading == Metrics.Tabs.collapsedSidebarLeading(isFullScreen: false))
    }
}
