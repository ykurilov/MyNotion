import AppKit
import NotesCore

extension BlockKind {
    /// Блок со своими редакторами внутри (колонки, таблица): его вид ставит редактор сам, поверх абзаца-вложения,
    /// а не TextKit. Такой вид живёт, пока абзац виден или пока в нём фокус, — курсор в колонке не пропадает
    /// при прокрутке, и вид есть и в окне вне экрана (проверки).
    var hostsEmbeddedEditors: Bool { self == .columnList || self == .table }
}

extension PageTextView {
    /// Виды колонок и таблиц над их абзацами в видимой части текста (с запасом в экран сверху и снизу).
    /// Абзац ушёл из видимой части — вид убирается, если в нём нет фокуса.
    func layoutEmbeddedViews() {
        guard !embeddedViews.isLayingOut else {
            embeddedViews.needsAnotherPass = true
            return
        }
        // Вид, поставленный впервые, узнаёт свою высоту и перекладывает абзац: ещё проход ставит его по новой высоте.
        for _ in 0..<3 {
            embeddedViews.needsAnotherPass = false
            embeddedViews.isLayingOut = true
            placeEmbeddedViews()
            embeddedViews.isLayingOut = false
            if !embeddedViews.needsAnotherPass { break }
        }
    }

    private func placeEmbeddedViews() {
        guard let textLayoutManager, let storage = textContentStorage, let textStorage else { return }
        let blocks = document.blocks
        guard blocks.contains(where: { $0.kind.hostsEmbeddedEditors }) || !embeddedViews.liveViews.isEmpty else { return }
        let origin = textContainerOrigin
        let visible = visibleRect.insetBy(dx: 0, dy: -max(visibleRect.height, 400))
        var placed: Set<UUID> = []
        let string = textStorage.string as NSString
        for (index, block) in blocks.enumerated() where block.kind.hostsEmbeddedEditors {
            let start = mapper.paragraphStart(ofBlockAt: index)
            guard start < string.length, let location = storage.location(storage.documentRange.location, offsetBy: start) else { continue }
            let existing = embeddedViews.view(for: block.id)
            let focused = existing.map(containsFirstResponder) ?? false
            // Раскладка — только когда абзац уже разложен рядом с видимой частью или в его виде фокус:
            // длинную страницу целиком не раскладываем.
            if !focused {
                guard let fragment = textLayoutManager.textLayoutFragment(for: location),
                      visible.intersects(fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)) else { continue }
            }
            textLayoutManager.ensureLayout(for: NSTextRange(location: location))
            guard let line = markerLine(ofBlockAt: index) else { continue }
            // Редакторы колонок сами отступают поле строки: их текст встаёт вровень с текстом страницы.
            let padding = block.kind == .columnList ? (textContainer?.lineFragmentPadding ?? 0) : 0
            let left = origin.x + line.caretX - padding
            let attachment = textStorage.attribute(.attachment, at: start, effectiveRange: nil) as? BlockAttachment
            let width = (attachment?.layoutWidth).map { $0 + padding }
                ?? max(0, origin.x + (textContainer?.size.width ?? 0) - (textContainer?.lineFragmentPadding ?? 0) - left)
            let frame = NSRect(x: left, y: origin.y + line.top, width: width, height: line.height)
            guard frame.intersects(visible) || focused else { continue }
            let view = existing ?? makeEmbeddedView(for: block, width: width)
            guard let view else { continue }
            if view.superview !== self { addSubview(view, positioned: .below, relativeTo: header) }
            if view.frame != frame { view.frame = frame }
            placed.insert(block.id)
        }
        for view in embeddedViews.liveViews where view.superview === self {
            guard let blockId = embeddedViews.blockId(of: view), !placed.contains(blockId) else { continue }
            if document.index(ofBlock: blockId) != nil, containsFirstResponder(view) { continue }
            view.removeFromSuperview()
            embeddedViews.unregister(blockId)
        }
    }

    private func makeEmbeddedView(for block: Block, width: CGFloat) -> NSView? {
        guard let view = BlockViewFactories.shared.factory(for: block.kind)?
            .makeView(for: block, context: BlockViewContext(textView: self, width: width)) else { return nil }
        embeddedViews.register(view, for: block.id)
        return view
    }

    private func containsFirstResponder(_ view: NSView) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    public override func viewWillDraw() {
        super.viewWillDraw()
        layoutEmbeddedViews()
    }
}
