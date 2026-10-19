import AppKit
import MathRendering
import VisualStyle

/// Какую формулу правит окно: блок или формулу в строке (блок и место знака в его тексте).
enum EquationTarget: Equatable {
    case block(UUID)
    case inline(blockId: UUID, location: Int)
}

/// Окно правки формулы под ней (contracts/blocks-and-keys.md, «Формула»): поле записи и живой показ, как у Notion.
/// Enter — готово, ⇧Enter — новая строка записи (у формулы в строке — тоже готово), Esc — отменить правку.
/// Щелчок мимо окна — готово.
@MainActor
final class EquationEditorController: NSObject, NSTextViewDelegate, NSPopoverDelegate {
    weak var textView: PageTextView?
    private(set) var target: EquationTarget?
    var isOpen: Bool { target != nil }
    let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
    let preview = NSImageView()
    let messageLabel = NSTextField(labelWithString: "")
    private(set) var previewResult: FormulaResult = .empty
    private let popover = NSPopover()
    private let fieldScroll = NSScrollView()

    var previewIsRendered: Bool {
        if case .rendered = previewResult { true } else { false }
    }

    static let width: CGFloat = 360

    override init() {
        super.init()
        field.isRichText = false
        field.allowsUndo = true
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.textColor = Palette.textPrimary
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.isAutomaticTextReplacementEnabled = false
        field.isContinuousSpellCheckingEnabled = false
        field.delegate = self
        field.setAccessibilityIdentifier("equation-field")
        field.textContainerInset = NSSize(width: 4, height: 6)
        field.isVerticallyResizable = true
        field.autoresizingMask = [.width]
        fieldScroll.documentView = field
        fieldScroll.hasVerticalScroller = true
        fieldScroll.autohidesScrollers = true
        fieldScroll.borderType = .noBorder
        fieldScroll.wantsLayer = true
        fieldScroll.layer?.cornerRadius = 4
        fieldScroll.layer?.borderWidth = 1
        fieldScroll.layer?.borderColor = Palette.border.cgColor
        preview.imageScaling = .scaleProportionallyDown
        preview.setAccessibilityIdentifier("equation-preview")
        messageLabel.font = .systemFont(ofSize: 12)
        let done = NSButton(title: "Готово", target: self, action: #selector(doneClicked))
        done.bezelStyle = .push
        done.keyEquivalent = ""
        done.setAccessibilityIdentifier("equation-done")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 170))
        fieldScroll.frame = NSRect(x: 12, y: 96, width: Self.width - 24, height: 62)
        preview.frame = NSRect(x: 12, y: 40, width: Self.width - 24, height: 48)
        messageLabel.frame = NSRect(x: 12, y: 12, width: Self.width - 110, height: 18)
        done.frame = NSRect(x: Self.width - 92, y: 8, width: 80, height: 28)
        for view in [fieldScroll, preview, messageLabel, done] { content.addSubview(view) }
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
    }

    /// Открыть окно для формулы `target` с записью `latex` под местом `anchor` (координаты вида текста).
    func open(_ target: EquationTarget, latex: String, below anchor: NSRect) {
        if isOpen { commit() }
        self.target = target
        field.string = latex
        field.setSelectedRange(NSRange(location: (latex as NSString).length, length: 0))
        field.undoManager?.removeAllActions(withTarget: field.textStorage as Any)
        updatePreview()
        guard let textView, let window = textView.window, window.isVisible else { return }
        popover.show(relativeTo: anchor.isEmpty ? NSRect(origin: anchor.origin, size: NSSize(width: 1, height: 1)) : anchor,
                     of: textView, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(field)
    }

    /// Готово: запись — в формулу.
    func commit() {
        guard let target else { return }
        self.target = nil
        let latex = field.string
        close()
        textView?.applyEquation(latex, to: target)
        textView.map { $0.window?.makeFirstResponder($0) }
    }

    /// Отменить правку: формула остаётся как была.
    func cancel() {
        guard target != nil else { return }
        target = nil
        close()
        textView.map { $0.window?.makeFirstResponder($0) }
    }

    private func close() {
        if popover.isShown { popover.performClose(nil) }
    }

    private func updatePreview() {
        let mode: FormulaMode = if case .inline = target { .inline } else { .display }
        let theme = FormulaTheme(textView?.effectiveAppearance ?? NSAppearance.currentDrawing())
        previewResult = FormulaImageCache.shared.render(field.string, fontSize: EquationBlockStyle.fontSize, theme: theme, mode: mode)
        switch previewResult {
        case .rendered(let formula):
            preview.image = formula.image
            messageLabel.stringValue = ""
        case .empty:
            preview.image = nil
            messageLabel.stringValue = FormulaImageCache.emptyFormulaText
            messageLabel.textColor = Palette.textSecondary
        case .invalid:
            preview.image = nil
            messageLabel.stringValue = FormulaImageCache.invalidFormulaText
            messageLabel.textColor = Palette.destructiveText
        }
    }

    @objc private func doneClicked() { commit() }

    // MARK: Поле записи

    func textDidChange(_ notification: Notification) {
        updatePreview()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            guard case .block? = target else {
                commit()
                return true
            }
            field.insertText("\n", replacementRange: field.selectedRange())
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    /// Щелчок мимо окна закрывает его — запись сохраняется, как у Notion.
    func popoverDidClose(_ notification: Notification) {
        if isOpen { commit() }
    }
}
