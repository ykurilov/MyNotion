import AppKit
import NotesCore
import VisualStyle

/// Страница версии «только чтение» (research R11, проба R15 п. 3): тот же редактор на документе из снимка, но без ввода,
/// команд и правок; блоки, отличные от текущей страницы, — на синеватой подложке, как в истории версий Notion 7.39.
@MainActor
public final class VersionPreviewTextView: PageTextView {
    /// Блоки потока страницы, которые подсветить.
    public var highlightedBlockIds: Set<UUID> = [] {
        didSet { if highlightedBlockIds != oldValue { needsDisplay = true } }
    }

    /// Подложка изменённого блока (≈ `notion-version-history.png`).
    static let highlightColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 35 / 255, green: 131 / 255, blue: 226 / 255, alpha: 0.16)
            : NSColor(srgbRed: 35 / 255, green: 131 / 255, blue: 226 / 255, alpha: 0.10)
    }

    // Ни фокуса, ни команд, ни правок: документ версии не меняется ничем.
    public override var acceptsFirstResponder: Bool { false }
    public override func perform(_ command: EditorCommand) {}
    public override func toggleCheckbox(ofBlock id: UUID) {}
    public override func keyDown(with event: NSEvent) { nextResponder?.keyDown(with: event) }
    public override func insertText(_ string: Any, replacementRange: NSRange) {}
    public override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool { false }
    // Наведение не показывает ни ручек «⋮⋮», ни кнопок шапки и обложки.
    public override func mouseMoved(with event: NSEvent) {}
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        stripHoverTracking()
    }

    /// Снять отслеживание мыши у видов внутри страницы (шапка, обложка, виды блоков): версия только для чтения.
    func stripHoverTracking() {
        func strip(_ view: NSView) {
            for area in view.trackingAreas { view.removeTrackingArea(area) }
            view.subviews.forEach(strip)
        }
        subviews.forEach(strip)
    }

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !highlightedBlockIds.isEmpty else { return }
        Self.highlightColor.setFill()
        for highlight in highlightRects(in: rect) {
            NSBezierPath(roundedRect: highlight, xRadius: Metrics.BlockSelection.cornerRadius, yRadius: Metrics.BlockSelection.cornerRadius).fill()
        }
    }

    /// Подложки подсвеченных блоков среди уже разложенных абзацев в `rect`: раскладку ради подсветки не заказываем.
    private func highlightRects(in rect: NSRect) -> [NSRect] {
        guard let layoutManager = textLayoutManager, let storage = textContentStorage, let container = textContainer else { return [] }
        let origin = textContainerOrigin
        let outset = Metrics.BlockSelection.horizontalOutset
        var rects: [NSRect] = []
        let top = CGPoint(x: 0, y: max(rect.minY - origin.y, 0))
        guard let first = layoutManager.textLayoutFragment(for: top) else { return [] }
        layoutManager.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            guard frame.minY < rect.maxY else { return false }
            let offset = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
            if let position = mapper.blockPosition(at: offset), position.index < document.blocks.count,
               highlightedBlockIds.contains(document.blocks[position.index].id) {
                let left = origin.x + blockLeft(ofBlockAt: position.index) - outset
                rects.append(NSRect(x: left, y: frame.minY, width: origin.x + container.size.width + outset - left, height: frame.height))
            }
            return true
        }
        return rects
    }
}
