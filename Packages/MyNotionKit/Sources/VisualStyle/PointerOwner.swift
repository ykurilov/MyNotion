#if canImport(AppKit)
import AppKit

/// Вид со своим указателем мыши: рука у нажимаемого (⋮⋮, +, иконка страницы, кнопки обложки).
/// Родитель с собственным cursorUpdate или mouseMoved (текст страницы, обложка) над таким видом
/// ставит его указатель, а не свой: иначе на каждом сдвиге мыши указатель мигает «свой → рука».
@MainActor public protocol PointerOwner: NSView {
    var pointer: NSCursor { get }
    /// Указатель в точке окна; nil — вид здесь указатель не выбирает, решает родитель.
    func pointer(atWindowPoint windowPoint: NSPoint) -> NSCursor?
}

extension PointerOwner {
    public func pointer(atWindowPoint windowPoint: NSPoint) -> NSCursor? { pointer }
}

extension NSView {
    /// Указатель вложенного вида-владельца под точкой окна; nil — под точкой такого вида нет.
    public func descendantPointer(atWindowPoint windowPoint: NSPoint) -> NSCursor? {
        guard let superview else { return nil }
        var hit = hitTest(superview.convert(windowPoint, from: nil))
        while let view = hit, view !== self {
            if let owner = view as? PointerOwner, let pointer = owner.pointer(atWindowPoint: windowPoint) { return pointer }
            hit = view.superview
        }
        return nil
    }
}
#endif
