import AppKit
import NotesCore

extension PageTextView {
    /// Щелчок по треугольнику переключателя, подписи свёрнутого заголовка, подсказке пустого переключателя или иконке выноски.
    func handleStructuralBlockClick(at point: NSPoint) -> Bool {
        if let id = toggle(at: point) {
            toggleCollapsed(ofBlock: id)
            return true
        }
        if let id = foldedLabel(at: point) {
            setCollapsed(false, ofBlock: id)
            return true
        }
        if let index = emptyToggleHint(at: point) {
            addFirstChild(toToggleAt: index)
            return true
        }
        if let id = calloutIcon(at: point) {
            openCalloutIconPicker(forBlock: id)
            return true
        }
        return false
    }

    /// Квадрат иконки выноски в координатах окна текста.
    public func calloutIconRect(ofBlock id: UUID) -> NSRect? {
        guard let index = document.index(ofBlock: id), document.blocks[index].kind == .callout,
              let line = markerLine(ofBlockAt: index) else { return nil }
        let origin = textContainerOrigin
        return CalloutBoxPainter.iconRect(indent: document.blocks[index].indent, line: line, originX: line.shift)
            .offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Выноска, чья иконка под точкой.
    func calloutIcon(at point: NSPoint) -> UUID? {
        guard let index = blockIndex(atY: point.y), document.blocks[index].kind == .callout,
              let rect = calloutIconRect(ofBlock: document.blocks[index].id), rect.contains(point) else { return nil }
        return document.blocks[index].id
    }

    /// Окно эмодзи 001 под иконкой выноски, без «Убрать» (у выноски иконка есть всегда).
    public func openCalloutIconPicker(forBlock id: UUID) {
        guard let window, let rect = calloutIconRect(ofBlock: id) else { return }
        let anchor = window.convertToScreen(convert(rect, to: nil))
        iconPicker.show(below: anchor, in: window, allowsRemoving: false) { [weak self] emoji in
            guard let emoji else { return }
            self?.setCalloutIcon(emoji, ofBlock: id)
        }
    }

    /// Новая иконка выноски — одно действие для ⌘Z.
    public func setCalloutIcon(_ icon: String, ofBlock id: UUID) {
        guard let index = document.index(ofBlock: id), document.blocks[index].kind == .callout else { return }
        var draft = BlockDraft(document.blocks[index])
        var props = draft.props ?? .defaults(for: .callout)
        props.icon = icon
        draft.props = props
        changeBlocks(index..<index + 1, to: [draft], actionName: "Иконка выноски")
    }
}
