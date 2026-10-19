import AppKit
import VisualStyle

/// Формулы LaTeX (research R6): исходники SwiftMath 1.7.3 (MIT) с одним шрифтом Latin Modern Math рисуют формулу
/// через CoreText. Отрисованная формула — картинка в кэше по (запись, размер, тема, вид); шрифт грузится при первой
/// формуле, а не при запуске.

/// Тема картинки: цвет чернил — textPrimary этой темы.
public enum FormulaTheme: Sendable, Hashable {
    case light
    case dark

    public init(_ appearance: NSAppearance) {
        self = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    var appearance: NSAppearance { NSAppearance(named: self == .dark ? .darkAqua : .aqua)! }
}

/// Формула-блок по центру колонки или формула в строке текста (мельче: пределы сумм сбоку, дроби ниже).
public enum FormulaMode: Sendable, Hashable {
    case display
    case inline
}

/// Картинка формулы и её базовая линия: `descent` — сколько картинки ниже базовой линии.
public struct RenderedFormula: @unchecked Sendable {
    public let image: NSImage
    public let ascent: CGFloat
    public let descent: CGFloat
}

public enum FormulaResult: @unchecked Sendable {
    /// Запись пустая: показать «Новая формула».
    case empty
    /// SwiftMath запись не разобрал: «Неверная формула»; сама запись не меняется (крайний случай spec).
    case invalid(String)
    case rendered(RenderedFormula)
}

@MainActor
public final class FormulaImageCache {
    public static let shared = FormulaImageCache()
    public static let emptyFormulaText = "Новая формула"
    public static let invalidFormulaText = "Неверная формула"

    private struct Key: Hashable {
        var latex: String
        var fontSize: CGFloat
        var theme: FormulaTheme
        var mode: FormulaMode
    }

    private var images: [Key: FormulaResult] = [:]
    /// Порядок использования: старые вытесняются, когда картинок больше `capacity`.
    private var order: [Key] = []
    private let capacity: Int
    /// Сколько раз формула рисовалась, а не бралась из кэша.
    public private(set) var renderCount = 0
    public private(set) var isFontLoaded = false

    public init(capacity: Int = 300) {
        self.capacity = capacity
    }

    public func render(_ latex: String, fontSize: CGFloat, theme: FormulaTheme, mode: FormulaMode = .display) -> FormulaResult {
        guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        let key = Key(latex: latex, fontSize: fontSize, theme: theme, mode: mode)
        if let cached = images[key] {
            if let position = order.firstIndex(of: key) { order.append(order.remove(at: position)) }
            return cached
        }
        let result = draw(key)
        renderCount += 1
        images[key] = result
        order.append(key)
        if order.count > capacity { images[order.removeFirst()] = nil }
        return result
    }

    private func draw(_ key: Key) -> FormulaResult {
        isFontLoaded = true
        var error: NSError?
        guard let font = MTFontManager.fontManager.latinModernFont(withSize: key.fontSize),
              let list = MTMathListBuilder.build(fromString: key.latex, error: &error), error == nil,
              let display = MTTypesetter.createLineForMathList(list, font: font, style: key.mode == .display ? .display : .text) else {
            return .invalid(error?.localizedDescription ?? Self.invalidFormulaText)
        }
        var color = NSColor.black
        key.theme.appearance.performAsCurrentDrawingAppearance { color = Palette.textPrimary.usingColorSpace(.sRGB) ?? .black }
        display.textColor = color
        let ascent = ceil(display.ascent)
        let descent = ceil(display.descent)
        let size = NSSize(width: max(1, ceil(display.width)), height: max(1, ascent + descent))
        display.position = CGPoint(x: 0, y: descent)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            display.draw(context)
            context.restoreGState()
            return true
        }
        return .rendered(RenderedFormula(image: image, ascent: ascent, descent: descent))
    }
}
