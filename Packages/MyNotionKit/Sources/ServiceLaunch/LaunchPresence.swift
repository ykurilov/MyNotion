import AppKit
import SwiftUI

/// Как запуск ведёт себя на экране (README, «Флаги запуска»). Служебные запуски — галерея, снимки, замеры —
/// идут, пока человек работает в других программах: они не забирают фокус, не всплывают и не стоят в Dock.
public enum LaunchPresence: Equatable, Sendable {
    /// Обычный запуск человеком.
    case foreground
    /// Служебный запуск: без значка в Dock, приложение нельзя активировать, окна за всеми окнами.
    case background

    /// Флаги служебных режимов. Новый служебный флаг — сюда же.
    public static let serviceFlags: Set<String> = [
        "--ui-gallery", "--ui-gallery-only", "--window-snapshot", "--hover-sidebar-row",
        "--generate-reference-library", "--launch-report", "--typing-benchmark", "--search-benchmark", "--export-markdown",
    ]
    /// Флаги, за которыми идёт значение: значение — не флаг, даже если похоже.
    static let flagsWithValue: Set<String> = [
        "--database", "--generate-reference-library", "--launch-report", "--window-snapshot", "--typing-benchmark",
        "--search-benchmark",
        "--ui-gallery", "--ui-gallery-only", "--hover-sidebar-row", "--appearance", "--export-markdown",
    ]

    /// `--generate-visual-sample` сам по себе — для человека (сверка с Notion); вместе со снимком — служебный.
    public init(arguments: [String]) {
        var flags: Set<String> = []
        var remaining = arguments.dropFirst()[...]
        while let argument = remaining.popFirst() {
            flags.insert(argument)
            if Self.flagsWithValue.contains(argument) { _ = remaining.popFirst() }
        }
        self = flags.isDisjoint(with: Self.serviceFlags) ? .foreground : .background
    }

    /// `.prohibited`, а не `.accessory`: такое приложение не активирует ни SwiftUI, ни случайный щелчок.
    public var activationPolicy: NSApplication.ActivationPolicy {
        self == .background ? .prohibited : .regular
    }

    /// Уровень рабочего стола: окно рисуется и снимается как обычно, но лежит под всеми окнами.
    /// Меню, поповеры и дочерние окна наследуют этот уровень.
    public var windowLevel: WindowLevel {
        self == .background ? .desktop : .automatic
    }
}
