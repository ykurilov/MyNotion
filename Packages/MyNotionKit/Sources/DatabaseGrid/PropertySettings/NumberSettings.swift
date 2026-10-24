import AppKit
import Databases
import NotesCore
import VisualStyle

/// Настройки числа (T073, `notion-edit-property-number.png`, `notion-number-show-as-bar.png`): «Формат числа ›» с
/// фильтром и прокруткой, «Знаки после запятой ›», «Показывать как» — плитки Число / Полоса / Кольцо; у полосы и кольца
/// «Цвет ›», «Разделить на» и «Показывать число»; внизу — «Изменения применяются ко всем видам с этим свойством».
@MainActor
final class NumberSettingsView: TypeSettingsView {
    nonisolated static let settings = PropertyTypeSettings(kinds: [.number]) { NumberSettingsView(context: $0) }

    private var divideField: PropertyPopupField?
    private let configKey: String?

    override convenience init(context: PropertyTypeSettingsContext) {
        self.init(context: context, configKey: nil)
    }

    /// Сводка использует те же строки и операции, но хранит оформление внутри `numberFormat`.
    init(context: PropertyTypeSettingsContext, configKey: String?, showsNote: Bool = true, defaultFormat: String = "number") {
        self.configKey = configKey
        super.init(context: context)
        var config = configKey.map { context.property.config[$0] ?? .emptyObject } ?? context.property.config
        if config["format"] == nil { config["format"] = .string(defaultFormat) }
        let format = NumberDisplay.format(config["format"]?.string)
        let decimals = config["decimals"]?.number.map(Int.init)
        _ = row("Формат числа", icon: "number", detail: format.title, identifier: "number-format") { [weak self] row in
            self?.showChoices(NumberDisplay.formats.map { .init(id: $0.id, title: $0.title, detail: $0.code) }, checked: format.id, besides: row,
                              width: 280, filterPlaceholder: "Фильтр форматов…", identifier: "number-format-list") { id in
                self?.updateConfig { $0["format"] = id == "number" && self?.configKey == nil ? nil : .string(id) }
            }
        }
        _ = row("Знаки после запятой", icon: "textformat.123", detail: NumberDisplay.decimalsTitle(decimals), identifier: "number-decimals") { [weak self] row in
            self?.showChoices(NumberDisplay.decimalChoices.map { .init(id: $0.map(String.init) ?? "auto", title: NumberDisplay.decimalsTitle($0)) },
                              checked: decimals.map(String.init) ?? "auto", besides: row, width: 180, identifier: "number-decimals-list") { id in
                self?.updateConfig { $0["decimals"] = Int(id).map { .number(Double($0)) } }
            }
        }
        stack.append(PropertyPopupCaption("Показывать как"), height: PropertyPopupMetrics.captionHeight, inset: 0)
        let style = NumberDisplay.style(config)
        let tiles = ShowAsTilesView(selected: style)
        tiles.onChoose = { [weak self] chosen in
            self?.updateConfig { config in
                let showAs = NumberDisplay.showAs(chosen, keeping: config)
                config["showAs"] = showAs
            }
        }
        stack.append(tiles, height: ShowAsTilesView.height, inset: 0)
        if style != .number, let showAs = config["showAs"] {
            let color = showAs["color"]?.string.flatMap(OptionColor.init(rawValue:)) ?? .green
            let colorRow = row("Цвет", icon: nil, detail: color.title, identifier: "number-color") { [weak self] row in
                self?.showChoices(OptionColor.allCases.map { .init(id: $0.rawValue, title: $0.title, swatch: $0) }, checked: color.rawValue,
                                  besides: row, identifier: "number-color-list") { id in
                    self?.updateConfig { $0["showAs"]?["color"] = .string(id) }
                }
            }
            colorRow.swatch = color
            let divisor = showAs["divideBy"]?.number ?? 100
            let field = PropertyPopupField(text: NumberDisplay.plain(divisor), placeholder: "100", identifier: "number-divide-by")
            field.onEndEditing = { [weak self] text in self?.commitDivisor(text) }
            field.onCommand = { [weak self, weak field] selector in
                guard selector == #selector(NSResponder.insertNewline(_:)), let field else { return false }
                self?.commitDivisor(field.text)
                return true
            }
            divideField = field
            stack.append(LabeledFieldRow(title: "Разделить на", field: field), height: PropertyPopupMetrics.nameBlockHeight, inset: 0)
            let showNumber = PopupToggleRow(title: "Показывать число", isOn: showAs["showNumber"]?.bool != false, identifier: "number-show-number")
            showNumber.onToggle = { [weak self] on in self?.updateConfig { $0["showAs"]?["showNumber"] = .bool(on) } }
            stack.append(showNumber, height: PropertyPopupMetrics.rowHeight, inset: 0)
        }
        if showsNote {
            stack.append(NoteLabel("Изменения применяются ко всем видам с этим свойством."), height: 36, inset: 0)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func updateConfig(_ edit: (inout JSONValue) -> Void) {
        guard let configKey else { return super.updateConfig(edit) }
        super.updateConfig { config in
            var number = config[configKey] ?? .emptyObject
            edit(&number)
            config[configKey] = number
        }
    }

    private func commitDivisor(_ text: String) {
        guard let number = NumberDisplay.parse(text), number > 0 else { return NSSound.beep() }
        updateConfig { $0["showAs"]?["divideBy"] = .number(number) }
    }
}

/// Плитки «Показывать как»: «42 Число», полоса, кольцо; выбранная — синей рамкой.
@MainActor
final class ShowAsTilesView: NSView {
    static let height: CGFloat = 64
    private var selected: NumberDisplay.Style
    var onChoose: ((NumberDisplay.Style) -> Void)?

    init(selected: NumberDisplay.Style) {
        self.selected = selected
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Показывать как")
        setAccessibilityIdentifier("number-show-as")
        setAccessibilityValue(selected.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private func tile(_ index: Int) -> NSRect {
        let gap: CGFloat = 6, inset = PropertyPopupMetrics.padding
        let width = (bounds.width - 2 * inset - 2 * gap) / 3
        return NSRect(x: inset + CGFloat(index) * (width + gap), y: 4, width: width, height: Self.height - 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        let small = NSFont.systemFont(ofSize: 11)
        for (index, style) in NumberDisplay.Style.allCases.enumerated() {
            let rect = tile(index)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            path.lineWidth = style == selected ? 2 : 1
            (style == selected ? Palette.focusRing : Palette.border).setStroke()
            path.stroke()
            let sample = NSRect(x: rect.midX - 14, y: rect.minY + 8, width: 28, height: 18)
            switch style {
            case .number:
                let text = NSAttributedString(string: "42", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: Palette.textPrimary])
                text.draw(at: NSPoint(x: sample.midX - text.size().width / 2, y: sample.minY))
            case .bar:
                Palette.switchOff.setFill()
                NSBezierPath(roundedRect: NSRect(x: sample.minX - 4, y: sample.midY - 2, width: sample.width + 8, height: 4), xRadius: 2, yRadius: 2).fill()
                Palette.focusRing.setFill()
                NSBezierPath(roundedRect: NSRect(x: sample.minX - 4, y: sample.midY - 2, width: (sample.width + 8) * 0.6, height: 4), xRadius: 2, yRadius: 2).fill()
            case .ring:
                let ring = NSRect(x: sample.midX - 8, y: sample.midY - 8, width: 16, height: 16)
                let track = NSBezierPath(ovalIn: ring.insetBy(dx: 1.5, dy: 1.5))
                track.lineWidth = 3
                Palette.switchOff.setStroke()
                track.stroke()
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: ring.midX, y: ring.midY), radius: 6.5, startAngle: -90, endAngle: 126)
                arc.lineWidth = 3
                Palette.focusRing.setStroke()
                arc.stroke()
            }
            let title = NSAttributedString(string: style.title, attributes: [.font: small, .foregroundColor: Palette.textSecondary])
            title.draw(at: NSPoint(x: rect.midX - title.size().width / 2, y: rect.maxY - 18))
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = (0..<3).first(where: { tile($0).contains(point) }) else { return }
        choose(NumberDisplay.Style.allCases[index])
    }

    func choose(_ style: NumberDisplay.Style) {
        guard style != selected else { return }
        selected = style
        setAccessibilityValue(style.title)
        needsDisplay = true
        onChoose?(style)
    }
}

/// Название слева и поле справа («Разделить на 100»).
@MainActor
final class LabeledFieldRow: NSView {
    private let title: String
    private let field: NSView

    init(title: String, field: NSView) {
        self.title = title
        self.field = field
        super.init(frame: .zero)
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = Typography.popupMenuTitle
        NSAttributedString(string: title, attributes: [.font: style.font, .foregroundColor: Palette.textPrimary])
            .draw(at: NSPoint(x: PropertyPopupMetrics.padding, y: (bounds.height - style.lineHeight) / 2))
    }
}

/// Серая подпись мелким шрифтом под настройками.
@MainActor
final class NoteLabel: NSView {
    private let text: String

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.textSecondary])
            .draw(with: bounds.insetBy(dx: PropertyPopupMetrics.padding, dy: 4), options: [.usesLineFragmentOrigin])
    }
}
