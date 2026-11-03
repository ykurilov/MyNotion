import AppKit
import PageEditor
import SwiftUI

/// «Вид → Увеличить / Уменьшить / Обычный размер текста» ⌘+, ⌘−, ⌘0: масштаб текста страниц во всех окнах
/// (`PageTextZoom`). ⌘= на той же клавише, что «+», ловит `AppDelegate`: у меню одно сочетание на пункт.
struct TextZoomCommands: Commands {
    private let zoom = PageTextZoom.shared

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Увеличить текст") { zoom.zoomIn() }
                .keyboardShortcut("+")
                .disabled(!zoom.canZoomIn)
            Button("Уменьшить текст") { zoom.zoomOut() }
                .keyboardShortcut("-")
                .disabled(!zoom.canZoomOut)
            Button("Обычный размер текста") { zoom.reset() }
                .keyboardShortcut("0")
                .disabled(zoom.isActualSize)
        }
    }
}
