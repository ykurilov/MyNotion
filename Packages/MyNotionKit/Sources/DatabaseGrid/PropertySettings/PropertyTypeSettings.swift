import AppKit
import Databases
import NotesCore

/// Окно настроек типа в панели «Изменить свойство» — раздел `typeSettings` (contracts/property-types.md): файл
/// `PropertySettings/<Тип>Settings.swift` истории (US2 — число, выбор, статус, дата; US4 — связь, сводка; US5 — формула)
/// объявляет описатель и добавляет его в `all`. У простых типов раздела нет.
public struct PropertyTypeSettings: Sendable {
    public let kinds: Set<PropertyKind>
    /// Вид раздела шириной панели; высота — `fittingSize` вида.
    public let makeView: @MainActor @Sendable (PropertyTypeSettingsContext) -> NSView

    public init(kinds: Set<PropertyKind>, makeView: @escaping @MainActor @Sendable (PropertyTypeSettingsContext) -> NSView) {
        self.kinds = kinds
        self.makeView = makeView
    }

    /// Описатели историй; в US1 окон типов нет.
    public static var all: [PropertyTypeSettings] { [] }

    static func settings(for kind: PropertyKind) -> PropertyTypeSettings? { all.first { $0.kinds.contains(kind) } }
}

/// Что получает окно типа: свойство и операции базы.
@MainActor
public struct PropertyTypeSettingsContext {
    public let property: DatabaseProperty
    public let store: NotesStore
    public let operations: DatabaseOperations
    public let viewId: UUID?
}
