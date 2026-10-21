import AppKit
import Foundation
import Testing
@testable import DatabaseGrid
@testable import Databases
@testable import NotesCore

/// Префикс ID в панели «Изменить свойство» (T039, Notion: «Prefix» у ID).
@MainActor
@Suite("Настройки ID: префикс")
struct UniqueIdSettingsTests {
    @Test("У ID есть раздел настроек; поле «Префикс» пишет префикс без пробелов по краям")
    func prefixField() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("idsettings-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        let operations = DatabaseOperations(store: store)
        let base = try operations.createDatabase(in: nil, isInline: false, title: "Задачи")
        let id = try operations.addProperty(to: base.databaseId, name: "ID", kind: .uniqueId)
        let settings = try #require(PropertyTypeSettings.settings(for: .uniqueId))
        let view = try #require(settings.makeView(PropertyTypeSettingsContext(property: id, store: store, operations: operations,
                                                                               viewId: base.viewId)) as? UniqueIdSettingsView)
        view.commit(prefix: "  ЗАД ")
        #expect(try store.write { try $0.property(id.id)?.config["prefix"]?.string } == "ЗАД")
        view.commit(prefix: "")
        #expect(try store.write { try $0.property(id.id)?.config["prefix"] } == nil, "пустой — без префикса")
    }
}
