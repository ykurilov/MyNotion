import AppKit
import DatabaseGrid
import Databases
import NotesCore
import VisualStyle

/// Страница окна вида: столбик строк в прокрутке, пересборка по правке базы. Одна и та же страница встаёт в карточку
/// под кнопкой и на страницу панели «Настройки вида».
@MainActor
class PanelPage: NSView {
    unowned let panels: ViewPanels
    let width: CGFloat
    let stack = PropertyPopupStack()
    private let scroll = NSScrollView()
    /// Уровень выпадающих списков страницы: у карточки и панели — 1, у окна значения в расширенном фильтре — 2.
    var menuLevel = 1
    var onResize: (() -> Void)?
    /// Окно больше нечего показывать (фильтр удалён): закрыть.
    var onFinish: (() -> Void)?

    init(panels: ViewPanels, width: CGFloat) {
        self.panels = panels
        self.width = width
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = stack
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var controller: DatabaseTableController { panels.controller }
    var size: NSSize { NSSize(width: width, height: min(stack.contentHeight, PanelMetrics.maxHeight)) }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        stack.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(stack.contentHeight, bounds.height))
    }

    /// Собрать строки заново.
    final func rebuild() {
        stack.removeAll()
        build()
        needsLayout = true
        onResize?()
    }

    /// Строки страницы.
    func build() {}

    /// После правки базы: по умолчанию — пересборка; страницы с полями ввода сверяют раскладку.
    func reload() { rebuild() }

    /// Поле страницы в фокусе — шаг ввода ещё не записан.
    func flush() {}

    /// Высота строки сменилась — без пересборки.
    final func resizeRow(_ view: NSView, to height: CGFloat) {
        stack.setHeight(height, of: view)
        needsLayout = true
        onResize?()
    }

    // MARK: Общие строки

    func row(_ title: String, icon: String?, value: String? = nil, chevron: Bool = false, destructive: Bool = false, identifier: String? = nil,
             action: @escaping (PropertyPopupRow) -> Void) -> PropertyPopupRow {
        let row = PropertyPopupRow(title: title, icon: icon, value: value, showsChevron: chevron, identifier: identifier)
        row.isDestructive = destructive
        row.onPress = { [weak row] in if let row { action(row) } }
        stack.append(row, height: PropertyPopupMetrics.rowHeight)
        return row
    }

    func separator() { stack.append(PropertyPopupSeparator(), height: PropertyPopupMetrics.separatorHeight) }

    func edit(_ body: (DatabaseOperations, UUID) throws -> Void) { controller.editView(body) }
}

/// Отложенная запись поля: правка пишется после паузы ввода или сразу при уходе из поля — одним шагом ⌘Z, а не на
/// каждый символ.
@MainActor
final class PausedWriter {
    private var timer: Timer?
    private var pending: (() -> Void)?

    func schedule(_ write: @escaping () -> Void) {
        pending = write
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    func flush() {
        timer?.invalidate()
        timer = nil
        let write = pending
        pending = nil
        write?()
    }
}
