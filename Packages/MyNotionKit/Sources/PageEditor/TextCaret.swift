import AppKit
import CoreText
import VisualStyle

/// Курсор текста как в Notion (contracts/visual-style.md, «Курсор»): черта шириной `Metrics.Caret.width`
/// на высоту букв шрифта строки, цвета текста, в просвете между буквами. Системный курсор на всю строку
/// текстовое поле не рисует (`shouldDrawInsertionPoint`), вместо него — этот вид поверх текста.
@MainActor
public final class TextCaret {
    /// Снимки галереи: курсор виден без ключевого окна и не мигает.
    public static var isPreviewMode = false

    let view = CaretView()
    private weak var textView: NSTextView?
    /// Курсор виден и в неключевом окне (проверки).
    var showsWithoutKeyWindow = false
    private var isLit = true
    private var blinkTimer: Timer?

    init(textView: NSTextView) {
        self.textView = textView
        view.isHidden = true
        textView.addSubview(view)
    }

    var frame: NSRect { view.frame }
    var isShown: Bool { !view.isHidden }

    /// Поставить курсор к выделению и зажечь: после набора, перемещения, смены фокуса и окна.
    /// Зовётся после смены выделения, а не из её уведомления: раскладка посреди смены сбивает места абзацев.
    /// `isFocused: false` — текст отдаёт фокус: окно ещё считает его первым, но курсор уже гаснет.
    func update(isFocused: Bool? = nil) {
        isLit = true
        guard let textView, isFocused != false, let rect = Self.rect(in: textView), isVisible(in: textView) else {
            view.isHidden = true
            stopBlinking()
            return
        }
        if textView.subviews.last !== view { textView.addSubview(view, positioned: .above, relativeTo: nil) }
        view.frame = rect
        view.isHidden = false
        startBlinking()
    }

    /// Один такт мигания.
    func blink() {
        guard let textView, isVisible(in: textView) else { return }
        isLit.toggle()
        view.isHidden = !isLit
    }

    private func isVisible(in textView: NSTextView) -> Bool {
        guard let window = textView.window, window.firstResponder === textView, textView.selectedRange().length == 0 else { return false }
        return window.isKeyWindow || showsWithoutKeyWindow || Self.isPreviewMode
    }

    private func startBlinking() {
        stopBlinking()
        guard !Self.isPreviewMode else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: Metrics.Caret.blinkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.blink() }
        }
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    // MARK: Где стоит курсор

    /// Прямоугольник курсора у пустого выделения (координаты окна текста): по высоте — от верха до низа шрифта
    /// на базовой линии строки, по ширине — в просвете между соседними буквами.
    static func rect(in textView: NSTextView) -> NSRect? {
        let selection = textView.selectedRange()
        guard selection.length == 0, let place = linePlace(of: selection.location, in: textView) else { return nil }
        let font = caretFont(at: selection.location, in: textView)
        let scale = textView.window?.backingScaleFactor ?? 2
        let x = caretX(boundary: place.x, gap: place.gap, scale: scale)
        let top = ((place.baseline - font.ascender) * scale).rounded() / scale
        let bottom = ((place.baseline - font.descender) * scale).rounded() / scale
        return NSRect(x: x, y: top, width: Metrics.Caret.width, height: bottom - top)
    }

    /// Левый край курсора: с границы букв вправо, как у Notion, но в пределах просвета `gap` и по пикселям экрана.
    /// Между двумя буквами — по середине просвета: так курсор дальше всего от обеих.
    static func caretX(boundary: CGFloat, gap: ClosedRange<CGFloat>, scale: CGFloat) -> CGFloat {
        let width = Metrics.Caret.width
        let isBetweenLetters = gap.lowerBound > -.greatestFiniteMagnitude && gap.upperBound < .greatestFiniteMagnitude
        let wanted = isBetweenLetters
            ? (gap.lowerBound + gap.upperBound - width) / 2
            : min(max(boundary, gap.lowerBound), gap.upperBound - width)
        let down = (wanted * scale).rounded(.down) / scale
        let up = (wanted * scale).rounded(.up) / scale
        let fits = { (x: CGFloat) in x >= gap.lowerBound && x + width <= gap.upperBound }
        if fits(down) && fits(up) { return wanted - down <= up - wanted ? down : up }
        return fits(up) ? up : down
    }

    private struct LinePlace {
        /// Граница букв, где TextKit ставит курсор.
        var x: CGFloat
        /// Просвет между рисунками соседних букв; со стороны, где буквы нет, — без края.
        var gap: ClosedRange<CGFloat>
        var baseline: CGFloat
    }

    /// Граница букв у `location`, просвет вокруг неё и базовая линия её строки по раскладке TextKit 2
    /// (координаты окна текста). Не `firstRect`: у последнего абзаца в одном фрагменте лежит пустая строка
    /// за переводом строки, и `firstRect` теряет отступ пункта.
    private static func linePlace(of location: Int, in textView: NSTextView) -> LinePlace? {
        guard let layoutManager = textView.textLayoutManager, let storage = layoutManager.textContentManager as? NSTextContentStorage,
              let textLocation = storage.location(storage.documentRange.location, offsetBy: location) else { return nil }
        // Раскладка с начала текста: абзац, разложенный раньше предыдущих, встаёт на прикидочное место.
        layoutManager.ensureLayout(for: NSTextRange(location: storage.documentRange.location, end: textLocation) ?? NSTextRange(location: textLocation))
        let atEnd = location >= (textView.textStorage?.length ?? 0)
        var found: NSTextLayoutFragment? = atEnd ? nil : layoutManager.textLayoutFragment(for: textLocation)
        if found == nil {
            // Конец текста (в названии): последний фрагмент.
            layoutManager.enumerateTextLayoutFragments(from: storage.documentRange.endLocation,
                                                       options: [.reverse, .ensuresLayout, .ensuresExtraLineFragment]) { fragment in
                found = fragment
                return false
            }
        }
        guard let fragment = found else { return nil }
        let fragmentStart = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
        let offset = location - fragmentStart
        let lines = fragment.textLineFragments
        guard let line = lines.first(where: { $0.characterRange.contains(offset) })
            ?? lines.last(where: { $0.characterRange.length > 0 && NSMaxRange($0.characterRange) == offset })
            ?? lines.first else { return nil }
        let frame = fragment.layoutFragmentFrame
        let origin = textView.textContainerOrigin
        let bounds = line.typographicBounds
        let left = origin.x + frame.minX + bounds.minX
        let x = left + line.locationForCharacter(at: offset).x
        let lineStartX = left + line.locationForCharacter(at: line.characterRange.location).x
        let gap = letterGap(at: offset - line.characterRange.location,
                            in: line.attributedString.attributedSubstring(from: line.characterRange), lineStartX: lineStartX)
        return LinePlace(x: x, gap: gap, baseline: origin.y + frame.minY + bounds.minY + line.glyphOrigin.y)
    }

    /// Просвет между рисунком буквы перед местом `offset` строки и рисунком буквы после него — по тем местам букв,
    /// где их рисует CoreText. Место курсора TextKit при кернинге делит сдвиг пары, и буква стоит не у него.
    /// Знак без рисунка (пробел, перевод строки) и начало строки курсор не теснят.
    private static func letterGap(at offset: Int, in lineText: NSAttributedString, lineStartX: CGFloat) -> ClosedRange<CGFloat> {
        let text = lineText.string as NSString
        let previous = offset > 0 ? text.rangeOfComposedCharacterSequence(at: offset - 1).location : nil
        var gapStart = -CGFloat.greatestFiniteMagnitude
        var gapEnd = CGFloat.greatestFiniteMagnitude
        var firstGlyphX: CGFloat?
        let line = CTLineCreateWithAttributedString(lineText)
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            for glyph in 0..<count {
                if firstGlyphX == nil { firstGlyphX = positions[glyph].x }
                guard indices[glyph] == previous || indices[glyph] == offset else { continue }
                let ink = CTRunGetImageBounds(run, nil, CFRange(location: glyph, length: 1))
                guard !ink.isNull, ink.width > 0 else { continue }
                // Рисунки — от начала строки CoreText; перевод к началу строки TextKit.
                let shift = lineStartX - (firstGlyphX ?? 0)
                if indices[glyph] == offset { gapEnd = min(gapEnd, ink.minX + shift) } else { gapStart = max(gapStart, ink.maxX + shift) }
            }
        }
        return gapStart...max(gapStart, gapEnd)
    }

    /// Шрифт буквы перед курсором — им продолжится набор; в начале строки и в пустом тексте — шрифт набора.
    private static func caretFont(at location: Int, in textView: NSTextView) -> NSFont {
        let fallback = textView.typingAttributes[.font] as? NSFont ?? textView.font ?? Typography.line(for: .paragraph).font
        guard let storage = textView.textStorage, location > 0, location <= storage.length,
              ![0x0A, 0x2028].contains((storage.string as NSString).character(at: location - 1)) else { return fallback }
        return storage.attribute(.font, at: location - 1, effectiveRange: nil) as? NSFont ?? fallback
    }

}

/// Текст, который сам рисует курсор (`TextCaret`): снимку окна дорисовывать системный курсор не нужно.
public protocol DrawsOwnCaret: NSTextView {}

extension PageTextView: DrawsOwnCaret {}
extension PageTitleEditor: DrawsOwnCaret {}

/// Черта курсора: залита цветом текста.
final class CaretView: NSView {
    var color: NSColor = Palette.textPrimary {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Редактор названия страницы: тот же курсор и то же выделение, что в блоках.
final class PageTitleEditor: NSTextView {
    private(set) lazy var caret = TextCaret(textView: self)

    /// Редактор на TextKit 2, как текст страницы: по его раскладке ставится курсор.
    static func make() -> PageTitleEditor {
        let editor = PageTitleEditor(usingTextLayoutManager: true)
        editor.isFieldEditor = true
        editor.insertionPointColor = .clear
        editor.selectedTextAttributes = [.backgroundColor: Palette.textSelection]
        _ = editor.caret
        return editor
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var shouldDrawInsertionPoint: Bool { false }

    override func becomeFirstResponder() -> Bool {
        defer { caret.update() }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer { caret.update(isFocused: false) }
        return super.resignFirstResponder()
    }

    override func didChangeText() {
        super.didChangeText()
        caret.update()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        caret.update()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        caret.update()
    }
}
