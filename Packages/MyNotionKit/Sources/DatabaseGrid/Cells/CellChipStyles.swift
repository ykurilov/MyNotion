import AppKit
import Attachments
import ImageIO
import NotesCore
import VisualStyle
import Databases

/// Плашки US2 особого вида в сетке, окнах и группах: статус — скругление в полвысоты и точка цвета (Notion 7.39,
/// `notion-status-cell-popup.png`), картинка из «Файлов и медиа» — уменьшенной копией.
@MainActor
enum CellChipStyles {
    static let dotSide: CGFloat = 6
    static let dotSpacing: CGFloat = 5

    /// Нарисовать плашку особого вида левым краем в `origin.x`, по середине `origin.y`; обычная — `nil`.
    /// Возвращает ширину нарисованного.
    static func draw(_ chip: CellPresentation.Chip, at origin: CGPoint, maxX: CGFloat, store: NotesStore) -> CGFloat? {
        if let id = chip.thumbnailId {
            let side = Metrics.DatabaseGrid.chipHeight + 4
            let rect = NSRect(x: origin.x, y: origin.y - side / 2, width: side, height: side)
            guard let image = FileThumbnails.shared.image(id, store: store) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
            image.draw(in: aspectFill(image.size, in: rect), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return side
        }
        guard chip.showsDot else { return nil }
        let size = statusSize(chip.title)
        let rect = NSRect(x: origin.x, y: origin.y - size.height / 2, width: min(size.width, maxX - origin.x), height: size.height)
        drawStatus(title: chip.title, color: chip.color, in: rect)
        return rect.width
    }

    static func statusSize(_ title: String) -> NSSize {
        let base = OptionChip.size(for: title)
        return NSSize(width: base.width + dotSide + dotSpacing, height: base.height)
    }

    /// Плашка статуса в рамке текущего (перевёрнутого) контекста.
    static func drawStatus(title: String, color: OptionColor, in rect: NSRect) {
        let radius = rect.height / 2
        Palette.optionChipBackground(color.rawValue).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let padding = Metrics.DatabaseGrid.chipHorizontalPadding
        statusDot(color).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + padding, y: rect.midY - dotSide / 2, width: dotSide, height: dotSide)).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: Metrics.DatabaseGrid.chipFontSize)
        let textHeight = font.ascender - font.descender
        let textX = rect.minX + padding + dotSide + dotSpacing
        (title as NSString).draw(with: NSRect(x: textX, y: rect.midY - textHeight / 2, width: max(0, rect.maxX - padding - textX), height: textHeight),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: font, .foregroundColor: Palette.optionChipText, .paragraphStyle: paragraph])
    }

    /// Точка статуса — насыщенный цвет варианта (у «По умолчанию» — серый).
    static func statusDot(_ color: OptionColor) -> NSColor {
        switch color {
        case .default, .gray: NSColor(srgbRed: 0.6, green: 0.59, blue: 0.57, alpha: 1)
        case .brown: NSColor(srgbRed: 0.62, green: 0.45, blue: 0.33, alpha: 1)
        case .orange: NSColor(srgbRed: 0.85, green: 0.45, blue: 0.05, alpha: 1)
        case .yellow: NSColor(srgbRed: 0.79, green: 0.57, blue: 0.16, alpha: 1)
        case .green: NSColor(srgbRed: 0.27, green: 0.6, blue: 0.4, alpha: 1)
        case .blue: NSColor(srgbRed: 0.18, green: 0.5, blue: 0.85, alpha: 1)
        case .purple: NSColor(srgbRed: 0.55, green: 0.39, blue: 0.75, alpha: 1)
        case .pink: NSColor(srgbRed: 0.76, green: 0.3, blue: 0.54, alpha: 1)
        case .red: NSColor(srgbRed: 0.83, green: 0.3, blue: 0.28, alpha: 1)
        }
    }

    static func aspectFill(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}

/// Уменьшенные копии картинок ячеек «Файлов и медиа» — по одной на файл, с диска один раз (ImageIO, до 96 точек).
/// Файла на этом Mac ещё нет (едет с другого Mac) — `nil`: сетка рисует плашку с именем.
@MainActor
final class FileThumbnails {
    static let shared = FileThumbnails()
    private let cache = NSCache<NSString, NSImage>()

    func image(_ id: UUID, store: NotesStore) -> NSImage? {
        if let image = cache.object(forKey: id.uuidString as NSString) { return image }
        let attachments = AttachmentStore(store: store, folder: AttachmentStore.folder(forDatabaseAt: store.database.url))
        guard case .ready(let url) = attachments.availability(of: id),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                             kCGImageSourceThumbnailMaxPixelSize: 96,
                                                                             kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        cache.setObject(image, forKey: id.uuidString as NSString)
        return image
    }
}
