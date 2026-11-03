import AppKit
import Observation

/// Масштаб текста страниц (⌘+, ⌘−, ⌘0, меню «Вид»): общий для приложения, хранится в настройках, а не в странице —
/// в историю версий и синхронизацию не попадает. Складывается с «мелким шрифтом» страницы (`PageLayoutSettings`).
/// Открытые редакторы следуют за ним по `didChange`.
@MainActor
@Observable
public final class PageTextZoom {
    public static let shared = PageTextZoom(defaults: .standard)
    public static let defaultsKey = "MyNotion.pageTextZoom"
    public static let didChange = Notification.Name("MyNotion.pageTextZoomDidChange")

    /// Шаги, как у масштаба Safari: от 75 до 200 %.
    public static let steps: [CGFloat] = [0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2]

    public private(set) var scale: CGFloat
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = (defaults.object(forKey: Self.defaultsKey) as? Double).map { CGFloat($0) } ?? 1
        scale = Self.steps.min { abs($0 - saved) < abs($1 - saved) } ?? 1
    }

    public var canZoomIn: Bool { scale < Self.steps.last! }
    public var canZoomOut: Bool { scale > Self.steps.first! }
    public var isActualSize: Bool { scale == 1 }

    public func zoomIn() { set(Self.steps.first { $0 > scale } ?? scale) }
    public func zoomOut() { set(Self.steps.last { $0 < scale } ?? scale) }
    public func reset() { set(1) }

    private func set(_ newScale: CGFloat) {
        guard newScale != scale else { return }
        scale = newScale
        defaults.set(Double(newScale), forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
