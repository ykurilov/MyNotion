import AppKit
import Databases
import NotesCore
import VisualStyle

/// Показ редактора формулы карточкой рядом с панелью «Изменить свойство» (как у Notion 7.39 — под пунктом
/// «Изменить формулу»). Закрывается «Готово», ×, Esc и щелчком мимо (несохранённое теряется, как у Notion).
@MainActor
public final class FormulaEditorPresenter {
    private let card = PopupCard()
    public private(set) var editor: FormulaEditorView?

    public init() {}

    public var isShown: Bool { card.isShown }

    /// Открыть редактор свойства `property`; `rows` — строки вида по порядку (первая — для предпросмотра).
    @discardableResult
    public func show(property: DatabaseProperty, rows: [UUID], operations: DatabaseOperations, besides anchor: NSView,
                     onSaved: (() -> Void)? = nil) throws -> FormulaEditorView {
        let model = try FormulaEditorModel(store: operations.store, property: property, rows: rows)
        let editor = FormulaEditorView(model: model, operations: operations)
        editor.onDone = { [weak self] in
            onSaved?()
            self?.close()
        }
        editor.onClose = { [weak self] in self?.close() }
        card.onClose = { [weak self] in self?.editor = nil }
        card.show(editor, size: FormulaEditorView.size, besides: anchor, preferringRight: false)
        self.editor = editor
        editor.focusField()
        return editor
    }

    public func close() {
        card.close()
        editor = nil
    }
}
