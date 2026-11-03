import AppKit
import VisualStyle

/// «Переименовать» вне дерева (меню ссылки на страницу): карточка с полем названия под строкой, как у Notion.
/// Enter или щелчок мимо сохраняют новое название, Esc — отмена.
@MainActor
public final class PageRenameCard: NSObject, NSTextFieldDelegate {
    private let card = PopupCard()
    private var field: NSTextField?
    private var original = ""
    private var commit: ((String) -> Void)?

    override public init() {
        super.init()
        card.onClose = { [weak self] in self?.finish() }
    }

    /// Показать под прямоугольником `anchor` (координаты экрана) в окне `window`.
    public func show(title: String, below anchor: NSRect, in window: NSWindow, commit: @escaping (String) -> Void) {
        card.close()
        guard let content = window.contentView else { return }
        let field = NSTextField(string: title)
        field.font = .systemFont(ofSize: Typography.popupMenuTitle.fontSize)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityIdentifier("page-rename-field")
        let size = NSSize(width: Metrics.PageMenu.width, height: 28 + 2 * Metrics.PopupMenu.verticalPadding)
        let box = NSView(frame: NSRect(origin: .zero, size: size))
        field.frame = NSRect(x: 8, y: Metrics.PopupMenu.verticalPadding, width: size.width - 16, height: 28)
        box.addSubview(field)
        self.field = field
        original = title
        self.commit = commit
        let point = window.convertFromScreen(anchor).origin
        card.show(box, size: size, from: point, in: content)
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            card.close()
        case #selector(NSResponder.cancelOperation(_:)):
            field?.stringValue = original
            card.close()
        default:
            return false
        }
        return true
    }

    /// Название поменялось — отдать его окну.
    private func finish() {
        guard let field, let commit else { return }
        self.field = nil
        self.commit = nil
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if title != original { commit(title) }
    }
}
