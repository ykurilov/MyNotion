import Foundation
import NotesCore

/// Раздел панели «Изменить свойство» (contracts/database-ui.md), по порядку.
public enum PropertySettingsSlot: Int, CaseIterable, Comparable, Sendable {
    case name, type, typeSettings, wrapText, duplicate, delete

    public static func < (lhs: PropertySettingsSlot, rhs: PropertySettingsSlot) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Описатель раздела: место и для каких типов. Настройки типа (`typeSettings`) — окно типа из файла
/// `PropertySettings/<Тип>Settings.swift` истории (US2 — числа, выбор, статус, дата; US4 — связь, сводка; US5 — формула).
public struct PropertySettingsSection: Sendable {
    public let slot: PropertySettingsSlot
    public let applies: @Sendable (PropertyKind) -> Bool

    public init(slot: PropertySettingsSlot, applies: @escaping @Sendable (PropertyKind) -> Bool = { _ in true }) {
        self.slot = slot
        self.applies = applies
    }
}

public enum PropertySettingsPanel {
    /// Типы со своими настройками (contracts/property-types.md, data-model.md, `config`).
    public static let typesWithSettings: Set<PropertyKind> = [.number, .select, .multiSelect, .status, .date, .relation, .rollup, .formula,
                                                              .uniqueId, .createdTime, .lastEditedTime]

    public static let all: [PropertySettingsSection] = [
        PropertySettingsSection(slot: .name),
        PropertySettingsSection(slot: .type) { $0 != .title },
        PropertySettingsSection(slot: .typeSettings) { typesWithSettings.contains($0) },
        PropertySettingsSection(slot: .wrapText),
        PropertySettingsSection(slot: .duplicate) { $0 != .title },
        PropertySettingsSection(slot: .delete) { $0 != .title },
    ]

    public static func sections(for kind: PropertyKind) -> [PropertySettingsSection] {
        all.filter { $0.applies(kind) }.sorted { $0.slot < $1.slot }
    }
}

extension PropertySettingsPanel {
    /// Разделы для типа, у которых есть обработчик окна (`handled`): раздел без обработчика не показывается.
    public static func sections(for kind: PropertyKind, handled: Set<PropertySettingsSlot>) -> [PropertySettingsSection] {
        sections(for: kind).filter { handled.contains($0.slot) }
    }
}
