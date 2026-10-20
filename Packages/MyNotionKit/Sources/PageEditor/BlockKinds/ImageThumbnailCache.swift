import AppKit
import ImageIO

/// Уменьшенные картинки под ширину блока (research R9): ImageIO читает файл сам и отдаёт картинку нужного размера —
/// исходник целиком в память не читается. Кэш в памяти до 48 МБ, вытесняемый.
@MainActor
final class ImageThumbnailCache {
    static let shared = ImageThumbnailCache()
    static let costLimit = 48 * 1_048_576

    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = ImageThumbnailCache.costLimit
        return cache
    }()

    /// Готовая уменьшенная картинка, если она уже в кэше.
    func cached(_ url: URL, maxPixelSize: Int) -> CGImage? {
        cache.object(forKey: Self.key(url, maxPixelSize))
    }

    /// Уменьшить в фоне; результат — на главном потоке.
    func thumbnail(_ url: URL, maxPixelSize: Int) async -> CGImage? {
        if let image = cached(url, maxPixelSize: maxPixelSize) { return image }
        let image = await Task.detached(priority: .userInitiated) { Self.decode(url, maxPixelSize: maxPixelSize) }.value
        if let image { cache.setObject(image, forKey: Self.key(url, maxPixelSize), cost: image.bytesPerRow * image.height) }
        return image
    }

    nonisolated static func decode(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func key(_ url: URL, _ size: Int) -> NSString {
        "\(url.path)#\(size)" as NSString
    }
}
