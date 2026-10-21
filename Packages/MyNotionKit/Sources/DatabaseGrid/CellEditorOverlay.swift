import AppKit
import VisualStyle

/// Правка ячейки на месте (contracts/database-ui.md, «Ячейки и клавиши»): поле поверх ячейки в синей рамке. Enter —
/// готово и ячейка ниже, Tab / ⇧Tab — готово и в сторону, Esc — готово, ячейка остаётся выбранной (как в Notion,
/// набранное не теряется). Ушёл фокус (щелчок мимо) — тоже готово.
@MainActor
final class CellEditorOverlay: NSView, NSTextFieldDelegate {
    let position: CellPosition
    private let field = NSTextField()
    private let initial: String
    /// Команда конца правки: шаг выбора (`nil` — остаться на ячейке).
    var onCommand: ((CellMove?) -> Void)?
    private var finished = false

    init(position: CellPosition, text: String, alignsRight: Bool, isTitle: Bool) {
        self.position = position
        initial = text
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.pageBackground.cgColor
        layer?.borderColor = Palette.focusRing.cgColor
        layer?.borderWidth = 1.5
        layer?.cornerRadius = 2
        field.stringValue = text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: Metrics.DatabaseGrid.fontSize, weight: isTitle ? .medium : .regular)
        field.textColor = Palette.textPrimary
        field.alignment = alignsRight ? .right : .left
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityIdentifier("database-cell-editor")
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    var text: String { field.stringValue }
    var isEdited: Bool { field.stringValue != initial }

    override func layout() {
        super.layout()
        let padding = Metrics.DatabaseGrid.cellHorizontalPadding
        let height = field.intrinsicContentSize.height
        field.frame = NSRect(x: padding - 2, y: (bounds.height - height) / 2, width: bounds.width - 2 * padding + 4, height: height)
    }

    /// Поле получает клавиши; курсор — в конец (первая буква уже стоит вместо содержимого).
    func focus(in window: NSWindow?) {
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    private func finish(_ move: CellMove?) {
        guard !finished else { return }
        finished = true
        onCommand?(move)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): finish(.down)
        case #selector(NSResponder.insertTab(_:)): finish(.tab)
        case #selector(NSResponder.insertBacktab(_:)): finish(.backtab)
        case #selector(NSResponder.cancelOperation(_:)): finish(nil)
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finish(nil)
    }
}
