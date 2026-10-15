import AppKit
import NotesCore
import VisualStyle

/// Ручки блока под мышью (contracts/visual-style.md, «Ручки блока при наведении»): слой поверх текста слева
/// от колонки. «+» добавляет блок ниже (с ⌥ — выше), «⋮⋮» тянут, чтобы переставить блок, щелчок открывает меню блока.
@MainActor
final class BlockHandlesOverlay: NSView {
    private unowned let textView: PageTextView
    private let addHandle = BlockHandleButton(kind: .add)
    private let dragHandle = BlockHandleButton(kind: .drag)
    private let dropIndicator = NSView()
    /// Блок, у которого показаны ручки.
    private(set) var blockId: UUID?
    private var dragStart: NSPoint?
    private var isDragging = false

    init(textView: PageTextView) {
        self.textView = textView
        super.init(frame: .zero)
        isHidden = true
        addSubview(addHandle)
        addSubview(dragHandle)
        addHandle.frame = NSRect(origin: .zero, size: Metrics.BlockHandles.addButtonSize)
        dragHandle.frame = NSRect(origin: NSPoint(x: Metrics.BlockHandles.addButtonLeadingOffset - Metrics.BlockHandles.dragHandleLeadingOffset, y: 0),
                                  size: Metrics.BlockHandles.dragHandleSize)
        addHandle.onPress = { [weak self] event in self?.addBlock(above: event.modifierFlags.contains(.option)) }
        dragHandle.onMouseDown = { [weak self] event in self?.dragStart = event.locationInWindow }
        dragHandle.onMouseDragged = { [weak self] event in self?.drag(event) }
        dragHandle.onMouseUp = { [weak self] event in self?.endDrag(event) }

        dropIndicator.wantsLayer = true
        dropIndicator.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    /// Показать ручки у блока `index`, строка которого — `line` (координаты контейнера).
    func show(forBlockAt index: Int, line: BlockLine) {
        guard !isDragging else { return }
        if superview == nil { textView.addSubview(self) }
        if dropIndicator.superview == nil { textView.addSubview(dropIndicator) }
        blockId = textView.document.blocks[index].id
        let origin = textView.textContainerOrigin
        let columnLeft = origin.x
        let height = Metrics.BlockHandles.addButtonSize.height
        let width = Metrics.BlockHandles.addButtonLeadingOffset - Metrics.BlockHandles.dragHandleLeadingOffset + Metrics.BlockHandles.dragHandleSize.width
        frame = NSRect(x: columnLeft - Metrics.BlockHandles.addButtonLeadingOffset, y: origin.y + line.top + (line.height - height) / 2,
                       width: width, height: height)
        isHidden = false
    }

    func hide() {
        guard !isDragging else { return }
        isHidden = true
        blockId = nil
    }

    // MARK: «+»

    private func addBlock(above: Bool) {
        guard let blockId, let index = textView.document.index(ofBlock: blockId) else { return }
        textView.insertEmptyBlock(at: above ? index : index + 1, openingSlashMenu: true)
    }

    // MARK: «⋮⋮»

    private func drag(_ event: NSEvent) {
        guard let start = dragStart else { return }
        let distance = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
        if !isDragging, distance < Metrics.BlockHandles.dragThreshold { return }
        isDragging = true
        textView.autoscroll(with: event)
        let point = textView.convert(event.locationInWindow, from: nil)
        guard let gap = textView.dropGap(atY: point.y) else {
            dropIndicator.isHidden = true
            return
        }
        let origin = textView.textContainerOrigin
        let height = Metrics.BlockHandles.dropIndicatorHeight
        dropIndicator.frame = NSRect(x: origin.x, y: gap.y - height / 2, width: Metrics.Page.columnWidth, height: height)
        dropIndicator.layer?.backgroundColor = textView.resolvedColor(Palette.dropIndicator)
        dropIndicator.isHidden = false
    }

    private func endDrag(_ event: NSEvent) {
        defer {
            dragStart = nil
            isDragging = false
            dropIndicator.isHidden = true
        }
        guard let blockId else { return }
        if isDragging {
            let point = textView.convert(event.locationInWindow, from: nil)
            if let gap = textView.dropGap(atY: point.y) {
                textView.window?.makeFirstResponder(textView)
                textView.moveBlock(blockId, toGap: gap.index)
            }
            return
        }
        guard let window else { return }
        let handleOnScreen = window.convertToScreen(dragHandle.convert(dragHandle.bounds, to: nil))
        textView.openBlockMenu(forBlock: blockId, below: handleOnScreen)
    }
}

/// Одна ручка: «+» или шесть точек «⋮⋮» цвета handleIcon, при наведении — фон hoverBackground.
@MainActor
final class BlockHandleButton: NSView {
    enum Kind { case add, drag }

    let kind: Kind
    var onPress: ((NSEvent) -> Void)?
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?
    private var isHovered = false { didSet { needsDisplay = true } }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(kind == .add ? "Добавить блок" : "Переставить блок")
        setAccessibilityIdentifier(kind == .add ? "block-handle-add" : "block-handle-drag")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        switch kind {
        case .add: break
        case .drag: onMouseDown?(event)
        }
    }

    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }

    override func mouseUp(with event: NSEvent) {
        switch kind {
        case .add: if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?(event) }
        case .drag: onMouseUp?(event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let event = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 0) else { return false }
        switch kind {
        case .add: onPress?(event)
        case .drag:
            onMouseDown?(event)
            onMouseUp?(event)
        }
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Palette.hoverBackground.setFill()
            let radius = Metrics.BlockHandles.cornerRadius
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        Palette.handleIcon.set()
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        switch kind {
        case .add:
            // Плюс 12×12 линией 1,5 (≈ по снимку).
            let plus = NSBezierPath()
            plus.move(to: NSPoint(x: center.x - 6, y: center.y))
            plus.line(to: NSPoint(x: center.x + 6, y: center.y))
            plus.move(to: NSPoint(x: center.x, y: center.y - 6))
            plus.line(to: NSPoint(x: center.x, y: center.y + 6))
            plus.lineWidth = 1.5
            plus.lineCapStyle = .round
            plus.stroke()
        case .drag:
            // Шесть точек: два столбца по три, шаг 5 (≈ по снимку).
            let dot: CGFloat = 2.6
            for column in [-1.0, 1.0] {
                for row in [-1.0, 0.0, 1.0] {
                    let x = center.x + column * 2.5, y = center.y + row * 5
                    NSBezierPath(ovalIn: NSRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)).fill()
                }
            }
        }
    }
}

extension PageTextView {
    // MARK: Ручки блока

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["blockHandles"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["blockHandles": true]))
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let left = origin.x - Metrics.BlockHandles.addButtonLeadingOffset
        guard point.x >= left, point.x <= origin.x + Metrics.Page.columnWidth,
              let index = blockIndex(atY: point.y), let line = markerLine(ofBlockAt: index) else {
            if !blockHandles.frame.contains(point) { hideBlockHandles() }
            return
        }
        blockHandles.show(forBlockAt: index, line: line)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if !blockHandles.frame.contains(point) { hideBlockHandles() }
    }

    func hideBlockHandles() {
        if !blockHandles.isHidden { blockHandles.hide() }
    }

    /// Вставить пустой абзац на место `index` и, если нужно, сразу открыть меню «/».
    func insertEmptyBlock(at index: Int, openingSlashMenu: Bool) {
        commitEdits()
        let index = min(max(index, 0), document.blocks.count)
        changeBlocks(index..<index, to: [BlockDraft(id: nil)], actionName: "Добавить блок")
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: index), length: 0))
        hideBlockHandles()
        if openingSlashMenu {
            insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    /// Зазор для сброса блока на высоте `y` и линия зазора (координаты окна текста).
    func dropGap(atY y: CGFloat) -> (index: Int, y: CGFloat)? {
        let frames = visibleBlockFrames()
        guard let first = frames.first else { return nil }
        let local = BlockMoveController.gap(forPointerY: y, blockFrames: frames.map(\.frame))
        if local < frames.count {
            return (first.index + local, frames[local].frame.lowerBound)
        }
        let last = frames[frames.count - 1]
        return (last.index + 1, last.frame.upperBound)
    }

    /// Высоты видимых блоков (координаты окна текста) по порядку.
    func visibleBlockFrames() -> [(index: Int, frame: ClosedRange<CGFloat>)] {
        guard let textLayoutManager else { return [] }
        let originY = textContainerOrigin.y
        let visible = visibleRect
        var frames: [(index: Int, frame: ClosedRange<CGFloat>)] = []
        let start = textLayoutManager.textViewportLayoutController.viewportRange?.location ?? textLayoutManager.documentRange.location
        textLayoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + originY > visible.maxY { return false }
            guard let index = blockIndex(atY: frame.minY + originY + 1) else { return true }
            // Добавочная строка после последнего перевода строки — не блок.
            let lines = fragment.textLineFragments
            var bottom = frame.maxY
            if let extra = lines.last, extra.characterRange.length == 0, lines.count > 1 {
                bottom = frame.minY + extra.typographicBounds.minY
            }
            frames.append((index, frame.minY + originY...bottom + originY))
            return true
        }
        return frames
    }

    /// Цвет темы окна для слоёв (у слоя нет своей темы).
    func resolvedColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }
}
