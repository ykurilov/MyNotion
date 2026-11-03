import Foundation
import Testing
@testable import Databases
@testable import NotesCore
@testable import PageVersions

/// Версии страниц-строк (T101, research R15): снимок версии 2 хранит значения свойств и связи строки; правка ячейки или
/// связи ставит строку в очередь снимков, пачечная перезапись при смене типа — нет; восстановление возвращает значения
/// и связи, ⌘Z — текущие; снимок версии 1 читается, а восстановление по нему значения не трогает.
@MainActor
@Suite("Версии: строки баз")
struct RowVersionTests {
    let mac: VersionsTestMac
    let databases: DatabaseOperations
    let tasks: CreatedDatabase
    let note: DatabaseProperty
    let status: DatabaseProperty
    let project: DatabaseProperty
    let done: SelectOption
    let projectA: UUID, projectB: UUID
    let row: UUID

    init() throws {
        mac = try VersionsTestMac()
        databases = DatabaseOperations(store: mac.store)
        tasks = try databases.createDatabase(in: nil, isInline: false, title: "Задачи")
        let projects = try databases.createDatabase(in: nil, isInline: false, title: "Проекты")
        projectA = try databases.addRow(to: projects.databaseId, in: nil, title: "Дом")
        projectB = try databases.addRow(to: projects.databaseId, in: nil, title: "Работа")
        note = try databases.addProperty(to: tasks.databaseId, name: "Заметка", kind: .text)
        status = try databases.addProperty(to: tasks.databaseId, name: "Статус", kind: .select)
        done = try databases.createOption(in: status.id, named: "Готово")
        project = try databases.addRelation(to: tasks.databaseId, name: "Проект", target: projects.databaseId)
        row = try databases.addRow(to: tasks.databaseId, in: nil, title: "Позвонить")
    }

    private func text(_ string: String) -> JSONValue { ["runs": [], "string": .string(string)] }

    private func versionNow(_ pageId: UUID) async throws -> PageVersionInfo {
        mac.clock.advance(by: 61)
        return try #require(try await mac.recorder.recordPending(pageId) ?? mac.versionList(pageId).first)
    }

    private func restorer() -> VersionRestorer {
        VersionRestorer(recorder: mac.recorder, versions: mac.versions, operations: mac.tree)
    }

    private func values() throws -> RowValues { try #require(try mac.store.rowValues(row)) }
    private func cell(_ property: DatabaseProperty) throws -> JSONValue? {
        try values().cells.first { $0.propertyId == property.id }?.value
    }
    private func linkedProjects() throws -> [UUID] { try values().links.map(\.targetRowId) }

    @Test("Снимок строки — версия 2 со значениями свойств и связями; у обычной страницы значений нет")
    func snapshotHoldsValues() async throws {
        try databases.setCell(rowId: row, propertyId: note.id, value: text("купить хлеб"))
        try databases.pickOption(done.id, rowId: row, propertyId: status.id)
        try databases.linkRow(row, through: project.id, to: projectA)
        let version = try await versionNow(row)
        let snapshot = try #require(try mac.versions.snapshot(version.id))
        #expect(snapshot.snapshotVersion == 2)
        let rowValues = try #require(snapshot.rowValues)
        #expect(rowValues.cells.first { $0.propertyId == note.id }?.value == text("купить хлеб"))
        #expect(rowValues.cells.first { $0.propertyId == status.id }?.value == .string(done.id.databaseText))
        #expect(rowValues.relationPropertyIds == [project.id])
        #expect(rowValues.links.map(\.targetRowId) == [projectA])

        let page = try mac.page("Обычная", texts: ["а"])
        let plain = try await versionNow(page.id)
        #expect(try mac.versions.snapshot(plain.id)?.rowValues == nil)
    }

    @Test("Правка ячейки и связи ставит строку в очередь снимков; смена типа пачкой — нет")
    func cellEditMarksDue() async throws {
        _ = try await versionNow(row)
        #expect(try mac.versions.dueMark(ofPage: row) == nil)

        try databases.setCell(rowId: row, propertyId: note.id, value: text("правка"))
        #expect(try mac.versions.dueMark(ofPage: row) != nil, "правка ячейки")
        _ = try await versionNow(row)

        try databases.linkRow(row, through: project.id, to: projectB)
        #expect(try mac.versions.dueMark(ofPage: row) != nil, "новая связь")
        _ = try await versionNow(row)

        try mac.store.write { tx in try tx.setCells([(row, text("пачкой"))], propertyId: note.id) }
        #expect(try mac.versions.dueMark(ofPage: row) == nil, "пачечная перезапись при смене типа — не правка строки")
    }

    @Test("Восстановление возвращает значения и связи; ⌘Z — текущие; в итогах версии — «изменены свойства»")
    func restoreBringsValuesBack() async throws {
        try databases.setCell(rowId: row, propertyId: note.id, value: text("было"))
        try databases.pickOption(done.id, rowId: row, propertyId: status.id)
        try databases.linkRow(row, through: project.id, to: projectA)
        let version = try await versionNow(row)

        try databases.setCell(rowId: row, propertyId: note.id, value: text("стало"))
        try databases.setCell(rowId: row, propertyId: status.id, value: nil)
        try databases.unlinkRow(row, through: project.id, from: projectA)
        try databases.linkRow(row, through: project.id, to: projectB)
        let latest = try await versionNow(row)
        #expect(latest.summary.propertiesChanged)

        try await mac.undoable { try await restorer().restore(versionId: version.id, ofPage: row) }
        #expect(try cell(note) == text("было"))
        #expect(try cell(status) == .string(done.id.databaseText))
        #expect(try linkedProjects() == [projectA])

        mac.undoManager.undo()
        #expect(try cell(note) == text("стало"))
        #expect(try cell(status) == nil)
        #expect(try linkedProjects() == [projectB])
    }

    @Test("Восстановление не пишет несовместимое: «Выбор» стал «Текстом», вариант удалён; живые варианты возвращаются")
    func restoreSkipsIncompatibleValues() async throws {
        let kind = try databases.addProperty(to: tasks.databaseId, name: "Вид", kind: .select)
        let call = try databases.createOption(in: kind.id, named: "Звонок")
        let tags = try databases.addProperty(to: tasks.databaseId, name: "Метки", kind: .multiSelect)
        let red = try databases.createOption(in: tags.id, named: "Красная")
        let blue = try databases.createOption(in: tags.id, named: "Синяя")
        try databases.pickOption(done.id, rowId: row, propertyId: status.id)
        try databases.pickOption(call.id, rowId: row, propertyId: kind.id)
        try databases.setCell(rowId: row, propertyId: tags.id, value: .array([.string(red.id.databaseText), .string(blue.id.databaseText)]))
        let version = try await versionNow(row)

        try databases.changeType(kind.id, to: .text)
        try databases.deleteOption(done.id)
        try databases.deleteOption(red.id)
        let typed = try cell(kind)

        try await mac.undoable { try await restorer().restore(versionId: version.id, ofPage: row) }
        #expect(try cell(kind) == typed, "id варианта в «Текст» не пишется")
        #expect(try cell(status) == nil, "удалённый вариант не возвращается")
        #expect(try cell(tags) == .array([.string(blue.id.databaseText)]), "из нескольких вариантов возвращаются живые")
    }

    @Test("Первая версия строки после снимка версии 1 не пишет «изменены свойства»")
    func firstRowVersionAfterVersionOne() throws {
        let content = try #require(try mac.store.pageContent(row))
        var old = PageSnapshot(page: content.page, blocks: content.blocks)
        old.snapshotVersion = 1
        let current = PageSnapshot(page: content.page, blocks: content.blocks, rowValues: try values())
        #expect(!VersionDiff.summary(from: old, to: current).propertiesChanged)
    }

    @Test("Снимок версии 1 читается; восстановление по нему возвращает название, а значения свойств не трогает")
    func versionOneLeavesValues() async throws {
        try databases.setCell(rowId: row, propertyId: note.id, value: text("сейчас"))
        let content = try #require(try mac.store.pageContent(row))
        var old = PageSnapshot(page: content.page, blocks: content.blocks)
        old.snapshotVersion = 1
        old.title = "Старое название"
        let data = try old.compressed()
        let decoded = try PageSnapshot(compressed: data)
        #expect(decoded.rowValues == nil)
        let info = try mac.versions.save(old, pageId: row, createdAt: mac.clock.now, deviceName: "Mac A", summary: VersionSummary())

        try await restorer().restore(versionId: info.id, ofPage: row)
        #expect(try mac.store.pageContent(row)?.page.title == "Старое название")
        #expect(try cell(note) == text("сейчас"))
    }
}
