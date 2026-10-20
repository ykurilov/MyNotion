import Foundation
import Testing
@testable import NotesCore

/// Сборка и распад колонок (contracts/blocks-and-keys.md, «Колонки»; research R3): правки — блоки `BlockChanges`,
/// одна правка на действие, перенос сохраняет id блока.
@MainActor
@Suite("Колонки: сборка и распад")
struct ColumnLayoutTests {
    let folder: TemporaryFolder
    let store: NotesStore
    let pageId: UUID

    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        pageId = try store.write { tx in
            let page = try tx.createPage(title: "Колонки")
            for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            for (text, indent) in [("A", 0), ("B", 0), ("B.1", 1), ("C", 0), ("D", 0), ("E", 0), ("F", 0)] {
                key = .between(key, nil)
                try tx.insertBlock(Block(pageId: page.id, kind: .bulletItem, text: InlineText(text), indent: indent, sortKey: key!))
            }
            return page.id
        }
    }

    func openDocument() throws -> PageDocument {
        PageDocument(content: try #require(try store.pageContent(pageId)))
    }

    func id(_ text: String, in document: PageDocument) -> UUID {
        document.allBlocksForTests.first { $0.text.string == text }!.id
    }

    /// Поток страницы и колонки текстами: «[A|B B.1]».
    func describe(_ document: PageDocument) -> [String] {
        document.blocks.map { block in
            guard block.kind == .columnList else { return block.text.string }
            return "[" + document.flow(block.id).map { column in
                document.flow(column.id).map { $0.text.string }.joined(separator: " ")
            }.joined(separator: "|") + "]"
        }
    }

    @Test("Блок к правому краю другого — две колонки: цель слева, перенесённый справа; id те же")
    func twoColumns() throws {
        let document = try openDocument()
        let a = id("A", in: document)
        let moved = [id("B", in: document), id("B.1", in: document)]
        let changes = try #require(document.changesPlacing(moved, besideRightOf: a))
        document.apply(changes)
        #expect(describe(document) == ["[A|B B.1]", "C", "D", "E", "F"])
        let list = document.blocks[0]
        #expect(list.kind == .columnList)
        let columns = document.flow(list.id)
        #expect(columns.count == 2 && columns.allSatisfy { $0.kind == .column })
        #expect(document.flow(columns[1].id).map(\.id) == moved, "перенос сохраняет id")
        #expect(document.flow(columns[1].id).map(\.indent) == [0, 1], "поддерево — с прежней вложенностью от нуля")
    }

    @Test("К краю колонки — ещё колонка справа от неё, до 5; шестой нет")
    func upToFiveColumns() throws {
        let document = try openDocument()
        document.apply(try #require(document.changesPlacing([id("B", in: document), id("B.1", in: document)], besideRightOf: id("A", in: document))))
        document.apply(try #require(document.changesPlacing([id("C", in: document)], besideRightOf: id("A", in: document))))
        #expect(describe(document) == ["[A|C|B B.1]", "D", "E", "F"])
        document.apply(try #require(document.changesPlacing([id("D", in: document)], besideRightOf: id("B", in: document))))
        document.apply(try #require(document.changesPlacing([id("E", in: document)], besideRightOf: id("D", in: document))))
        #expect(describe(document) == ["[A|C|B B.1|D|E]", "F"])
        #expect(document.changesPlacing([id("F", in: document)], besideRightOf: id("E", in: document)) == nil)
    }

    @Test("Ширины колонок сбрасываются поровну, когда колонок становится больше")
    func ratiosResetOnNewColumn() throws {
        let document = try openDocument()
        document.apply(try #require(document.changesPlacing([id("B", in: document)], besideRightOf: id("A", in: document))))
        let list = document.blocks[0].id
        document.apply(try #require(document.changesSettingColumnRatios([0.3, 0.7], ofColumnList: list)))
        #expect(ColumnLayout.ratios(of: document.flow(list)) == [0.3, 0.7])
        document.apply(try #require(document.changesPlacing([id("C", in: document)], besideRightOf: id("B", in: document))))
        let ratios = ColumnLayout.ratios(of: document.flow(list))
        #expect(ratios.count == 3 && ratios.allSatisfy { abs($0 - 1.0 / 3) < 0.001 })
    }

    @Test("Граница колонок: доли 10–90 %, сумма 1")
    func ratiosClamped() throws {
        let document = try openDocument()
        document.apply(try #require(document.changesPlacing([id("B", in: document)], besideRightOf: id("A", in: document))))
        let list = document.blocks[0].id
        document.apply(try #require(document.changesSettingColumnRatios([0.02, 0.98], ofColumnList: list)))
        #expect(ColumnLayout.ratios(of: document.flow(list)) == [0.1, 0.9])
    }

    @Test("Последний блок унесли из колонки — колонка исчезает; осталась одна — колонки распадаются на месте")
    func emptyColumnDisappearsAndSingleDissolves() throws {
        let document = try openDocument()
        document.apply(try #require(document.changesPlacing([id("B", in: document)], besideRightOf: id("A", in: document))))
        document.apply(try #require(document.changesPlacing([id("C", in: document)], besideRightOf: id("B", in: document))))
        #expect(describe(document) == ["[A|B|C]", "B.1", "D", "E", "F"])
        // C — в конец страницы: третья колонка пуста и исчезает.
        document.apply(document.changesMoving([id("C", in: document)], to: nil, after: document.blocks.last!.id, before: nil))
        #expect(describe(document) == ["[A|B]", "B.1", "D", "E", "F", "C"])
        // B — под D: осталась одна колонка, её блоки встают на место колонок.
        let d = id("D", in: document)
        document.apply(document.changesMoving([id("B", in: document)], to: nil, after: d, before: id("E", in: document)))
        #expect(describe(document) == ["A", "B.1", "D", "B", "E", "F", "C"])
        #expect(document.allBlocksForTests.allSatisfy { $0.kind != .column && $0.kind != .columnList })

        let autosave = AutosaveCoordinator(document: document, store: store, scheduler: ManualAutosaveScheduler())
        #expect(autosave.saveNow())
        autosave.stop()
        #expect(describe(try openDocument()) == ["A", "B.1", "D", "B", "E", "F", "C"])
    }

    @Test("Перенос между колонками — одна правка места (containerId + sortKey), id тот же")
    func moveBetweenColumns() throws {
        let document = try openDocument()
        document.apply(try #require(document.changesPlacing([id("B", in: document)], besideRightOf: id("A", in: document))))
        let c = id("C", in: document)
        document.apply(try #require(document.changesPlacing([c], besideRightOf: id("B", in: document))))
        document.apply(try #require(document.changesPlacing([id("D", in: document)], besideRightOf: id("A", in: document))))
        #expect(describe(document) == ["[A|D|B|C]", "B.1", "E", "F"])
        let columns = document.flow(document.blocks[0].id)
        let changes = document.changesMoving([c], to: columns[0].id, after: id("A", in: document), before: nil)
        #expect(changes.upserts.contains { $0.id == c })
        document.apply(changes)
        #expect(describe(document) == ["[A C|D|B]", "B.1", "E", "F"])
        #expect(document.block(c)?.containerId == columns[0].id)
    }

    @Test("Обратная правка возвращает всё как было")
    func inverseRestores() throws {
        let document = try openDocument()
        let before = Set(document.allBlocksForTests)
        let inverse1 = document.apply(try #require(document.changesPlacing([id("B", in: document), id("B.1", in: document)], besideRightOf: id("A", in: document))))
        let inverse2 = document.apply(document.changesMoving([id("A", in: document)], to: nil, after: id("F", in: document), before: nil))
        #expect(describe(document) == ["B", "B.1", "C", "D", "E", "F", "A"])
        document.apply(inverse2)
        document.apply(inverse1)
        #expect(Set(document.allBlocksForTests) == before)
    }

    @Test("Блок нельзя поставить рядом с самим собой или внутрь своих колонок")
    func invalidTargets() throws {
        let document = try openDocument()
        let b = id("B", in: document)
        #expect(document.changesPlacing([b], besideRightOf: b) == nil)
        document.apply(try #require(document.changesPlacing([b], besideRightOf: id("A", in: document))))
        let list = document.blocks[0].id
        #expect(document.changesPlacing([list], besideRightOf: b) == nil)
    }
}
