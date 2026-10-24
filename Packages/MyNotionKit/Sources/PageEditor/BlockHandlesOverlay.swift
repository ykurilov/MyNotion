import AppKit
import NotesCore
import VisualStyle

/// Ручки блока под мышью (contracts/visual-style.md, «Ручки блока при наведении»): слой поверх текста слева
/// от колонки. «+» добавляет блок ниже (с ⌥ — выше), «⋮⋮» тянут, чтобы переставить блок, щелчок открывает меню блока.
/// Пока блок тянут, за мышью едет его полупрозрачная копия вместе с вложенными, место сброса — синяя линия; Esc отменяет.
@MainActor
final class BlockHandlesOverlay: NSView {
    private unowned let textView: PageTextView
    private let addHandle = BlockHandleButton(kind: .add)
    let dragHandle = BlockHandleButton(kind: .drag)
    let dropIndicator = BlockDropLine()
    let dragGhost = BlockDragGhost()
    /// Блок, у которого показаны ручки.
    private(set) var blockId: UUID?
    /// Где нажали «⋮⋮» (координаты окна).
    private var dragStart: NSPoint?
    /// Где была мышь и призрак, когда началось перетаскивание (координаты окна текста).
    private var ghostAnchor: (pointer: NSPoint, origin: NSPoint)?
    private(set) var isDragging = false
    /// Перетаскивание отменили по Esc: до отпускания мышь ничего не двигает.
    private var isCancelled = false

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
        dragHandle.onMouseDown = { [weak self] event in
            self?.dragStart = event.locationInWindow
            self?.isCancelled = false
        }
        dragHandle.onMouseDragged = { [weak self] event in self?.drag(event) }
        dragHandle.onMouseUp = { [weak self] event in self?.endDrag(event) }

        dropIndicator.isHidden = true
        dragGhost.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    /// Где живут ручки, призрак и линия сброса: текст страницы. У колонки ручки стоят левее её края, а призрак
    /// едет над всей страницей — поэтому они в редакторе страницы, а рамки переводятся из координат колонки.
    private var chromeHost: PageTextView { textView.pageEditor }

    /// Показать ручки у блока `index`, строка которого — `line` (координаты контейнера).
    func show(forBlockAt index: Int, line: BlockLine) {
        guard !isDragging else { return }
        let host = chromeHost
        if superview !== host { host.addSubview(self) }
        if dropIndicator.superview !== host { host.addSubview(dropIndicator) }
        if dragGhost.superview !== host { host.addSubview(dragGhost) }
        let block = textView.document.blocks[index]
        blockId = block.id
        let origin = textView.textContainerOrigin
        let columnLeft = origin.x
        let height = Metrics.BlockHandles.addButtonSize.height
        let width = Metrics.BlockHandles.addButtonLeadingOffset - Metrics.BlockHandles.dragHandleLeadingOffset + Metrics.BlockHandles.dragHandleSize.width
        // По середине строчных букв первой строки, как маркер списка: середина строки с отступом абзаца выше на 3–5.
        let font = Typography.line(for: PageTextStorageMapper.textStyle(of: block.kind)).font
        let centerY = origin.y + line.baseline - font.xHeight / 2
        frame = host.convert(NSRect(x: columnLeft - Metrics.BlockHandles.addButtonLeadingOffset, y: centerY - height / 2, width: width, height: height),
                             from: textView)
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
        guard let start = dragStart, !isCancelled else { return }
        let distance = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
        if !isDragging, distance < Metrics.BlockHandles.dragThreshold { return }
        let host = chromeHost
        if !isDragging { beginDrag(at: host.convert(start, from: nil)) }
        host.autoscroll(with: event)
        let point = host.convert(event.locationInWindow, from: nil)
        // Кадр за кадром без анимаций слоёв: призрак и линия не отстают от мыши и не мигают.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let ghostAnchor {
            dragGhost.setFrameOrigin(NSPoint(x: ghostAnchor.origin.x + point.x - ghostAnchor.pointer.x,
                                             y: ghostAnchor.origin.y + point.y - ghostAnchor.pointer.y))
        }
        guard let blockId, let frame = dropIndicatorFrame(forBlock: blockId, atWindowPoint: event.locationInWindow) else {
            dropIndicator.isHidden = true
            return
        }
        dropIndicator.frame = frame
        dropIndicator.isHidden = false
    }

    /// Линия места сброса (координаты страницы): между блоками — во всю ширину их потока, у правого края блока —
    /// вертикальная полоса по его высоте (`FlowDragCoordinator`).
    private func dropIndicatorFrame(forBlock blockId: UUID, atWindowPoint point: NSPoint) -> NSRect? {
        let host = chromeHost
        switch textView.dropTarget(forBlock: blockId, atWindowPoint: point) {
        case .gap?:
            let editor = FlowDragCoordinator.editor(atWindowPoint: point, in: host)
            guard let gap = editor.dropGap(atY: editor.convert(point, from: nil).y) else { return nil }
            let height = Metrics.BlockHandles.dropIndicatorHeight
            let width = editor.textContainer?.size.width ?? Metrics.Page.columnWidth
            return host.convert(NSRect(x: editor.textContainerOrigin.x, y: gap.y - height / 2, width: width, height: height), from: editor)
        case .besideRight(let targetId)?:
            guard let frame = host.frameInWindow(ofBlock: targetId) else { return nil }
            let local = host.convert(frame, from: nil)
            let width = Metrics.Columns.dropBarWidth
            return NSRect(x: local.maxX - width / 2, y: local.minY, width: width, height: local.height)
        case nil:
            return nil
        }
    }

    /// Мышь сдвинулась дальше порога: снять копию блока с вложенными и показать её на месте блока.
    private func beginDrag(at pointer: NSPoint) {
        isDragging = true
        // Esc приходит в окно текста, даже если до этого печатали в названии страницы.
        textView.window?.makeFirstResponder(textView)
        guard let blockId, let index = textView.document.index(ofBlock: blockId),
              let snapshot = textView.snapshot(ofBlocks: index..<BlockMoveController.subtreeEnd(textView.document.blocks, of: index)) else { return }
        dragGhost.image = snapshot.image
        dragGhost.frame = chromeHost.convert(snapshot.frame, from: textView)
        ghostAnchor = (pointer, dragGhost.frame.origin)
        chromeHost.addSubview(dragGhost, positioned: .above, relativeTo: nil)
        dragGhost.isHidden = false
    }

    /// Esc во время перетаскивания: блок остаётся на месте.
    func cancelDrag() {
        guard isDragging else { return }
        finishDrag()
        isCancelled = true
    }

    private func finishDrag() {
        dragStart = nil
        isDragging = false
        ghostAnchor = nil
        dropIndicator.isHidden = true
        dragGhost.isHidden = true
        dragGhost.image = nil
    }

    private func endDrag(_ event: NSEvent) {
        let wasDragging = isDragging, wasCancelled = isCancelled
        finishDrag()
        isCancelled = false
        guard let blockId, !wasCancelled else { return }
        if wasDragging {
            textView.dropBlock(blockId, atWindowPoint: event.locationInWindow)
            return
        }
        guard let window else { return }
        let handleOnScreen = window.convertToScreen(dragHandle.convert(dragHandle.bounds, to: nil))
        textView.selectBlockAndOpenMenu(blockId, below: handleOnScreen)
    }
}

/// Линия места сброса цвета dropIndicator во всю ширину колонки.
@MainActor
final class BlockDropLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Palette.dropIndicator.setFill()
        bounds.fill(using: .sourceOver)
    }
}

/// Копия блока с вложенными, которая едет за мышью, в dragGhostOpacity цвета, как в Notion.
/// Слой рисуется один раз: при сдвиге рамки картинка не перерисовывается.
@MainActor
final class BlockDragGhost: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: Metrics.BlockHandles.dragGhostOpacity,
                    respectFlipped: true, hints: nil)
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
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

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
        for area in trackingAreas where area.owner === self &&
            (area.userInfo?["blockHandles"] != nil || area.userInfo?["textPointer"] != nil) {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["blockHandles": true]))
        // Отдельная область: .inVisibleRect у ручек включает также шапку и обложку.
        // Здесь cursorUpdate NSTextView нужен только тексту и пустой части колонки.
        let cursorRect = textPointerRect.intersection(visibleRect)
        if !cursorRect.isEmpty {
            addTrackingArea(NSTrackingArea(rect: cursorRect, options: [.cursorUpdate, .activeInKeyWindow],
                                           owner: self, userInfo: ["textPointer": true]))
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateBlockHandles(atWindowPoint: event.locationInWindow)
        updatePointer(atWindowPoint: event.locationInWindow)
    }

    public override func cursorUpdate(with event: NSEvent) {
        // NSTextView регистрирует I-beam и над обложкой. Её собственный cursorUpdate
        // уже выбрал arrow/openHand; родитель не должен менять этот выбор.
        if let cover = coverSlot.view, cover.frame.contains(convert(event.locationInWindow, from: nil)) { return }
        // Ручки в gutter тоже принадлежат этому helper: поздний parent update
        // не должен затирать arrow, выбранную в mouseMoved дочерней кнопки.
        if updatePointer(atWindowPoint: event.locationInWindow) { return }
        if !textPointerRect.contains(convert(event.locationInWindow, from: nil)) {
            super.cursorUpdate(with: event)
        }
    }

    /// Одинаковое правило для обоих порядков доставки mouseMoved/cursorUpdate.
    @discardableResult
    private func updatePointer(atWindowPoint windowPoint: NSPoint) -> Bool {
        let point = convert(windowPoint, from: nil)
        let target = hitTest(convert(point, to: superview))
        var hit = target
        while let child = hit, child !== self {
            // Родитель тоже получает mouseMoved: не ждём отдельного cursorUpdate кнопки.
            if child is BlockHandleButton || child is PageIconView || child is PageHeaderButton { NSCursor.arrow.set(); return true }
            // Встроенные элементы управления выбирают собственный курсор.
            if child is NSControl, child !== emptyParagraphHint { return false }
            hit = child.superview
        }
        // Курсоры вложенных редакторов, разделителей и resize-ручек принадлежат их видам.
        guard target == nil || target === self || target === emptyParagraphHint ||
                target?.isDescendant(of: emptyParagraphHint) == true,
              textPointerRect.contains(point) else { return false }
        NSCursor.iBeam.set()
        return true
    }

    private var textPointerRect: NSRect {
        let origin = textContainerOrigin
        return NSRect(x: origin.x, y: origin.y, width: textContainer?.size.width ?? 0,
                      height: max(0, bounds.maxY - origin.y))
    }

    /// Ручки у блока под мышью. Над колонками ручки — у блока колонки под мышью, а не у всего блока колонок.
    func updateBlockHandles(atWindowPoint windowPoint: NSPoint) {
        guard showsBlockHandles else { return }
        let point = convert(windowPoint, from: nil)
        let origin = textContainerOrigin
        let left = origin.x - Metrics.BlockHandles.addButtonLeadingOffset
        let width = textContainer?.size.width ?? Metrics.Page.columnWidth
        guard point.x >= left, point.x <= origin.x + width,
              let index = blockIndex(atY: point.y), let line = markerLine(ofBlockAt: index) else {
            if !blockHandles.frame.contains(pageEditor.convert(windowPoint, from: nil)) { hideBlockHandles() }
            return
        }
        if document.blocks[index].kind == .columnList, let columns = columnsView(for: document.blocks[index].id) {
            let local = columns.convert(windowPoint, from: nil)
            if let editor = columns.editors.min(by: { abs($0.frame.midX - local.x) < abs($1.frame.midX - local.x) }) {
                hideBlockHandles()
                editor.updateBlockHandles(atWindowPoint: windowPoint)
                return
            }
        }
        blockHandles.show(forBlockAt: index, line: line)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if !blockHandles.frame.contains(pageEditor.convert(event.locationInWindow, from: nil)) { hideBlockHandles() }
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

    /// Снимок блоков `range` без фона страницы, курсора и ручек — картинка для призрака и её рамка (координаты окна текста).
    func snapshot(ofBlocks range: Range<Int>) -> (image: NSImage, frame: NSRect)? {
        let frames = visibleBlockFrames().filter { range.contains($0.index) }.map(\.frame)
        guard let top = frames.map(\.lowerBound).min(), let bottom = frames.map(\.upperBound).max() else { return nil }
        let rect = NSRect(x: textContainerOrigin.x, y: top, width: textContainer?.size.width ?? Metrics.Page.columnWidth, height: bottom - top)
        guard let bitmap = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        let chrome = ([blockHandles, emptyParagraphHint, slashQueryHighlight, caret.view] + insertionIndicators(in: self)).filter { !$0.isHidden }
        chrome.forEach { $0.isHidden = true }
        drawsBackground = false
        cacheDisplay(in: rect, to: bitmap)
        drawsBackground = true
        chrome.forEach { $0.isHidden = false }
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return (image, rect)
    }

    private func insertionIndicators(in view: NSView) -> [NSView] {
        view.subviews.flatMap { ($0 is NSTextInsertionIndicator ? [$0] : []) + insertionIndicators(in: $0) }
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
