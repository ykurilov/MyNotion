import AppKit
import PageTree

/// Снимок окна изнутри приложения (флаг `--window-snapshot`): для сверки с Notion, в том числе
/// когда экран Mac заблокирован и обычный снимок экрана выходит чёрным.
@MainActor
enum WindowSnapshot {
    /// Пауза после готовности страницы: дорисовать текст и полосы прокрутки.
    static let settleDelay: Duration = .seconds(1)
    /// Одинаковый размер окна у всех снимков, чтобы их можно было сравнивать.
    static let windowContentSize = NSSize(width: 1280, height: 860)

    static func capture(to url: URL, hoveredSidebarRow: Int? = nil) {
        NSApp.windows.first { $0.isVisible }?.setContentSize(windowContentSize)
        Task {
            try? await Task.sleep(for: settleDelay)
            if let hoveredSidebarRow, let window = NSApp.windows.first(where: { $0.isVisible }),
               !PageTreeHoverPreview.hoverRow(hoveredSidebarRow, in: window) {
                FileHandle.standardError.write(Data("Строки дерева \(hoveredSidebarRow) нет\n".utf8))
            }
            // Меню на снимок не попадает: названия — в вывод, чтобы проверить язык.
            print("Меню: " + (NSApp.mainMenu?.items.map(\.title).joined(separator: ", ") ?? "нет"))
            do {
                try write(to: url)
                print("Снимок окна: \(url.path)")
            } catch {
                FileHandle.standardError.write(Data("Снимок окна не создан: \(error.localizedDescription)\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }

    private static func write(to url: URL) throws {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let frameView = window.contentView?.superview else { throw SnapshotError.noWindow }
        let bounds = frameView.bounds
        guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { throw SnapshotError.noBitmap }
        frameView.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotError.noBitmap }
        try png.write(to: url, options: .atomic)
    }

    private enum SnapshotError: LocalizedError {
        case noWindow, noBitmap
        var errorDescription: String? {
            switch self {
            case .noWindow: "нет окна"
            case .noBitmap: "не удалось нарисовать окно"
            }
        }
    }
}
