import AppKit
import Databases
import NotesCore
import VisualStyle

/// Настройки ID в панели «Изменить свойство»: поле «Префикс» (Notion 7.39 «Prefix», `notion.com/help/unique-id`):
/// номер показывается «ЗАД-12». Пустой — без префикса. Правка — по Enter и уходу из поля, одним шагом ⌘Z.
@MainActor
final class UniqueIdSettingsView: NSView {
    nonisolated static let settings = PropertyTypeSettings(kinds: [.uniqueId]) { UniqueIdSettingsView(context: $0) }
    static let height: CGFloat = 64

    private let context: PropertyTypeSettingsContext
    private let caption = PropertyPopupCaption("Префикс")
    let field: PropertyPopupField

    init(context: PropertyTypeSettingsContext) {
        self.context = context
        field = PropertyPopupField(text: context.property.config["prefix"]?.string ?? "", placeholder: "Например, ЗАД",
                                   identifier: "unique-id-prefix")
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: Self.height))
        addSubview(caption)
        addSubview(field)
        field.onEndEditing = { [weak self] text in self?.commit(prefix: text) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { NSSize(width: frame.width, height: Self.height) }

    override func layout() {
        super.layout()
        caption.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 26)
        field.frame = NSRect(x: 0, y: 28, width: bounds.width, height: 32)
    }

    /// Записать префикс: пробелы по краям отбрасываются, пустой — ключ убирается.
    func commit(prefix: String) {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        // Настройки — как сейчас в хранилище (окно могло жить дольше правки с другого Mac).
        let stored = (try? context.store.write { try $0.property(context.property.id)?.config }) ?? nil
        var config = stored ?? context.property.config
        config["prefix"] = trimmed.isEmpty ? nil : .string(trimmed)
        guard config != stored else { return }
        do { try context.operations.setPropertyConfig(context.property.id, config) } catch { NSSound.beep() }
    }
}
