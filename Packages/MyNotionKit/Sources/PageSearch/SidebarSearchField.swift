import AppKit
import SwiftUI
import VisualStyle

/// Поле поиска вверху боковой панели (contracts/visual-style.md, «Боковая панель»): рамка border на фоне панели,
/// скругление 6, лупа и подсказка «Поиск». Ввод и выдачу ведёт `PageSearchController`.
public struct SidebarSearchField: NSViewRepresentable {
    let controller: PageSearchController

    public init(controller: PageSearchController) {
        self.controller = controller
    }

    public func makeNSView(context: Context) -> SearchFieldView {
        let view = SearchFieldView()
        view.textField.delegate = controller
        controller.fieldView = view
        return view
    }

    public func updateNSView(_ view: SearchFieldView, context: Context) {
        view.textField.delegate = controller
        controller.fieldView = view
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: SearchFieldView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: Metrics.SearchField.height)
    }
}

/// Рамка поля с лупой; внутри — строка ввода без своей рамки и фона.
public final class SearchFieldView: NSView {
    static let placeholder = "Поиск"

    let textField = SearchTextField()

    var isFocused = false {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        textField.placeholderAttributedString = NSAttributedString(string: Self.placeholder, attributes: [
            .font: Typography.sidebarRow.font,
            .foregroundColor: Palette.textSecondary,
        ])
        addSubview(textField)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        let metrics = Metrics.SearchField.self
        let height = textField.intrinsicContentSize.height
        textField.frame = NSRect(x: metrics.textX, y: ((bounds.height - height) / 2).rounded(),
                                 width: max(0, bounds.width - metrics.textX - metrics.textTrailingPadding), height: height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let metrics = Metrics.SearchField.self
        let inset = metrics.borderWidth / 2
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                 xRadius: metrics.cornerRadius, yRadius: metrics.cornerRadius)
        frame.lineWidth = metrics.borderWidth
        Palette.border.setStroke()
        frame.stroke()
        drawSymbol("magnifyingglass", size: metrics.iconSize, color: Palette.textSecondary,
                   center: NSPoint(x: metrics.iconCenterX, y: bounds.midY))
    }

    /// Щелчок по рамке или лупе — тоже в поле.
    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textField)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func drawSymbol(_ name: String, size: CGFloat, color: NSColor, center: NSPoint) {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return
        }
        image.draw(in: NSRect(x: (center.x - image.size.width / 2).rounded(), y: (center.y - image.size.height / 2).rounded(),
                              width: image.size.width, height: image.size.height))
    }
}

/// Строка ввода поиска: без рамки и фона, шрифт строк боковой панели.
final class SearchTextField: NSTextField {
    init() {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = Typography.sidebarRow.font
        textColor = Palette.textPrimary
        cell?.isScrollable = true
        cell?.wraps = false
        cell?.usesSingleLineMode = true
        lineBreakMode = .byClipping
        setAccessibilityIdentifier("sidebar-search")
        setAccessibilityLabel("Поиск страниц")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }
}
