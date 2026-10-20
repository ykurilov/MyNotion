import AppKit
import NotesCore

/// Вид блока без своего текста (research R2): картинка, файл, видео, закладка, формула, таблица, колонки.
/// Тяжёлые модули (вложения, видео, формулы) редактор знает только через этот протокол: фабрики регистрирует
/// приложение при запуске (plan.md, Structure Decision).
@MainActor
public protocol BlockViewFactory: AnyObject {
    /// Вид блока; создаётся, только когда строка блока входит в видимую область, и отпускается за ней.
    func makeView(for block: Block, context: BlockViewContext) -> NSView?
    /// Высота строки блока при ширине колонки `width`; `nil` — высота заглушки.
    func height(for block: Block, width: CGFloat) -> CGFloat?
    /// То же, когда известен редактор: высота колонок и таблицы зависит от их блоков в документе.
    func height(for block: Block, width: CGFloat, context: BlockViewContext) -> CGFloat?
}

extension BlockViewFactory {
    public func height(for block: Block, width: CGFloat, context: BlockViewContext) -> CGFloat? {
        height(for: block, width: width)
    }
}

/// Где живёт вид: текст страницы (для правок блока, например подписи) и ширина колонки.
public struct BlockViewContext {
    public weak var textView: PageTextView?
    public var width: CGFloat
}

/// Фабрики видов по типу блока.
@MainActor
public final class BlockViewFactories {
    public static let shared = BlockViewFactories()
    private var factories: [BlockKind: any BlockViewFactory] = [:]

    public func register(_ factory: any BlockViewFactory, for kind: BlockKind) {
        factories[kind] = factory
    }

    public func unregister(_ kind: BlockKind) {
        factories[kind] = nil
    }

    func factory(for kind: BlockKind) -> (any BlockViewFactory)? {
        factories[kind]
    }
}
