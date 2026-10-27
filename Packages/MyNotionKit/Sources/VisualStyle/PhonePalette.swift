#if canImport(UIKit)
import UIKit

/// Цвета страницы на iPhone: те же значения, что у `Palette` на Mac (`PaletteValues`), каждый сам переключается
/// вместе с темой iPhone.
public enum PhonePalette {
    public static let textPrimary = themed(PaletteValues.textPrimary)
    public static let textSecondary = themed(PaletteValues.textSecondary)
    public static let pageBackground = themed(PaletteValues.pageBackground)
    public static let border = themed(PaletteValues.border)
    public static let dividerLine = themed(PaletteValues.dividerLine)
    public static let inlineCodeText = themed(PaletteValues.inlineCodeText)
    public static let inlineCodeBackground = themed(PaletteValues.inlineCodeBackground)
    public static let checkboxChecked = themed(PaletteValues.checkboxChecked)
    public static let checkboxCheckmark = themed(PaletteValues.checkboxCheckmark)
    public static let handleIcon = themed(PaletteValues.handleIcon)
    public static let linkUnderline = themed(PaletteValues.linkUnderline)
    public static let pageHeaderButton = themed(PaletteValues.pageHeaderButton)
    public static let placeholder = themed(PaletteValues.placeholder)

    /// Цвет текста Notion; `nil` — основной цвет текста страницы.
    public static func notionText(_ tone: NotionTone?) -> UIColor {
        guard let tone else { return textPrimary }
        return notionTextColors[tone] ?? textPrimary
    }

    /// Цвет подложки Notion (фон текста или блока); `nil` — без подложки.
    public static func notionBackground(_ tone: NotionTone?) -> UIColor? {
        guard let tone else { return nil }
        return notionBackgroundColors[tone]
    }

    private static let notionTextColors: [NotionTone: UIColor] = Dictionary(uniqueKeysWithValues: NotionTone.allCases.map {
        ($0, themed(PaletteValues.notionText($0)))
    })

    private static let notionBackgroundColors: [NotionTone: UIColor] = Dictionary(uniqueKeysWithValues: NotionTone.allCases.map {
        ($0, themed(PaletteValues.notionBackground($0)))
    })

    private static func themed(_ color: ThemedPaletteColor) -> UIColor {
        let light = UIColor(color.light)
        let dark = UIColor(color.dark)
        return UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
    }
}

extension UIColor {
    fileprivate convenience init(_ color: PaletteRGBA) {
        self.init(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
#endif
