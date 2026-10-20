import AppKit
import PageEditor

/// Снимок окна вместе со всем, что приложение показывает поверх него: меню «/» и блока (дочерние окна),
/// окно корзины (поповер), диалоги. Рисуется изнутри приложения, поэтому работает и при заблокированном экране.
@MainActor
enum CompositeWindowSnapshot {
    static func png(of window: NSWindow) throws -> Data {
        guard let base = window.contentView?.superview.flatMap(render) else { throw SnapshotError.noBitmap }
        let scale = window.backingScaleFactor
        let size = window.frame.size
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw SnapshotError.noBitmap
        }
        // Размер в точках — до создания контекста: тогда рисование в точках ложится на все пиксели.
        canvas.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { throw SnapshotError.noBitmap }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        base.draw(in: NSRect(origin: .zero, size: size))
        for overlay in overlays(of: window) {
            let origin = NSPoint(x: overlay.frame.minX - window.frame.minX, y: overlay.frame.minY - window.frame.minY)
            let rect = NSRect(origin: origin, size: overlay.frame.size)
            if let content = popoverContent(of: overlay) {
                // Поповер: системное «стекло» с рамкой на снимке рисуется радугой. Вместо него — цвет окна в теме
                // главного окна, а поверх содержимое поповера (стрелка к якорю не рисуется).
                let frame = content.convert(content.bounds, to: nil)
                let area = NSRect(x: rect.minX + frame.minX, y: rect.minY + frame.minY, width: frame.width, height: frame.height)
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    NSBezierPath(roundedRect: area, xRadius: Self.popoverCornerRadius, yRadius: Self.popoverCornerRadius).fill()
                    NSColor.separatorColor.setStroke()
                    NSBezierPath(roundedRect: area.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.popoverCornerRadius, yRadius: Self.popoverCornerRadius).stroke()
                }
                if let image = render(content) { image.draw(in: area, from: .zero, operation: .sourceOver, fraction: 1) }
            } else if needsBackdrop(overlay) {
                // Фон диалога — системное «стекло»: снимок рисует его белым в любой теме. Вместо него —
                // цвет окна в теме главного окна, а поверх только содержимое диалога.
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: Self.dialogCornerRadius, yRadius: Self.dialogCornerRadius).fill()
                }
                guard let content = overlay.contentView, let image = render(content) else { continue }
                image.draw(in: NSRect(origin: NSPoint(x: rect.minX + content.frame.minX, y: rect.minY + content.frame.minY),
                                      size: content.frame.size), from: .zero, operation: .sourceOver, fraction: 1)
            } else if let image = overlay.contentView?.superview.flatMap(render) {
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        drawInsertionPoint(of: window)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = canvas.representation(using: .png, properties: [:]) else { throw SnapshotError.noBitmap }
        return png
    }

    /// Мигающий курсор система рисует отдельным слоем, и снимок вида его не видит: нарисовать его там,
    /// где его ставит текст (`firstRect` пустого выделения), цветом курсора текста. Курсор страницы и названия —
    /// свой вид (`DrawsOwnCaret`), он уже на снимке.
    private static func drawInsertionPoint(of window: NSWindow) {
        guard let textView = window.firstResponder as? NSTextView, !(textView is DrawsOwnCaret),
              textView.selectedRange().length == 0 else { return }
        let caret = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        guard caret.height > 0 else { return }
        let rect = NSRect(x: caret.minX - window.frame.minX, y: caret.minY - window.frame.minY,
                          width: Self.insertionPointWidth, height: caret.height)
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            (textView.insertionPointColor).setFill()
            rect.fill()
        }
    }

    /// Ширина системного курсора текста.
    static let insertionPointWidth: CGFloat = 2

    /// Окна приложения поверх `window`, от нижнего к верхнему: по уровню, внутри уровня — по порядку на экране.
    private static func overlays(of window: NSWindow) -> [NSWindow] {
        NSApp.windows
            .filter { $0 !== window && $0.isVisible && $0.frame.intersects(window.frame) && $0.contentView != nil }
            .sorted { ($0.level.rawValue, -$0.orderedIndex) < ($1.level.rawValue, -$1.orderedIndex) }
    }

    private static func needsBackdrop(_ window: NSWindow) -> Bool {
        window.sheetParent != nil || window.isModalPanel || window is NSPanel && window.styleMask.contains(.titled)
    }

    /// Содержимое поповера (`NSPopover`): сам вид, который положил в него код. Окно поповера вокруг него —
    /// «стекло» с рамкой и стрелкой, на снимке оно рисуется радугой.
    private static func popoverContent(of window: NSWindow) -> NSView? {
        guard NSStringFromClass(type(of: window)).contains("Popover") else { return nil }
        return window.contentView
    }

    static let popoverCornerRadius: CGFloat = 10

    /// Скругление системного диалога.
    static let dialogCornerRadius: CGFloat = 16

    private static func render(_ view: NSView) -> NSImage? {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    enum SnapshotError: LocalizedError {
        case noBitmap
        var errorDescription: String? { "не удалось нарисовать окно" }
    }
}
