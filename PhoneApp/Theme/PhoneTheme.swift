import SwiftUI
import UIKit

/// Цвета и размеры экранов iPhone. Цвета — те же, что в `Palette` Mac (contracts/visual-style.md): `Palette` собран на AppKit
/// и на iPhone недоступен, поэтому значения повторены здесь; светлая и тёмная тема переключаются сами.
enum PhoneTheme {
    static let textPrimary = themed(light: 0x2C2C2B, dark: 0xF0EFED)
    static let textSecondary = themed(light: 0x7D7A75, dark: 0x9B9A97)
    static let icon = themed(light: 0x5F5E59, dark: 0x9B9A97)
    static let pageBackground = themed(light: 0xFFFFFF, dark: 0x191919)
    static let groupedBackground = themed(light: 0xF9F8F7, dark: 0x202020)
    static let border = themed(light: 0xE6E5E3, dark: 0x2F2F2F)
    static let pressedBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.055) : UIColor(red: 33 / 255, green: 27 / 255, blue: 23 / 255, alpha: 0.05)
    })
    static let destructive = themed(light: 0xD44C47, dark: 0xFF7369)
    /// Кнопки действий — синий Notion.
    static let accent = themed(light: 0x2383E2, dark: 0x2383E2)

    /// Строка дерева: касание пальцем — не меньше 44 pt.
    static let rowHeight: CGFloat = 44
    /// Сдвиг подстраниц на уровень.
    static let rowIndent: CGFloat = 18
    static let rowIconSize: CGFloat = 24
    static let rowEmojiSize: CGFloat = 19
    static let rowTitleSize: CGFloat = 17
    /// Поля страницы на узком экране.
    static let pageHorizontalPadding: CGFloat = 20

    private static func themed(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in rgb(traits.userInterfaceStyle == .dark ? dark : light) })
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
