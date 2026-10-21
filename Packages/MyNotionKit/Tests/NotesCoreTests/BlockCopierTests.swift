import Foundation
import Testing
@testable import NotesCore

/// Общая копия блоков (research R7, R8): поддеревья, колонки и таблицы с новыми id — основа переноса в подстраницу,
/// «Переместить в», дублирования, шаблонов. Тесты «Преобразовать в → Страница» — `InlineSubpageTests`.
@Suite("Копия блоков")
struct BlockCopierTests {
    let source = UUID.timeOrdered()
    let target = UUID.timeOrdered()

    /// Поток страницы: абзац, вложенный пункт с цветом, колонки (2 колонки по блоку), таблица 2 × 2; и блок после.
    struct Sample {
        var all: [Block] = []
        var roots: [Block] = []
        var after: Block!
        var columnList: Block!
        var table: Block!
        var tableColumns: [Block] = []
        var cells: [Block] = []
    }

    func sample() -> Sample {
        var sample = Sample()
        var key: FractionalSortKey?
        func flow(_ kind: BlockKind, _ text: String = "", indent: Int, color: BlockColor = .none, props: BlockProps = .empty) -> Block {
            key = .between(key, nil)
            return Block(pageId: source, kind: kind, text: InlineText(text), indent: indent, sortKey: key!, color: color, props: props)
        }
        let paragraph = flow(.paragraph, "Абзац", indent: 2)
        let bullet = flow(.bulletItem, "Пункт", indent: 3, color: BlockColor(text: .red))
        let columnList = flow(.columnList, indent: 2)
        let table = flow(.table, indent: 3, props: BlockProps(["hasHeaderRow": .bool(true)]))
        sample.after = flow(.paragraph, "После", indent: 0)
        sample.roots = [paragraph, bullet, columnList, table]
        sample.columnList = columnList
        sample.table = table
        var inner: [Block] = []
        var columnKey: FractionalSortKey?
        for number in 1...2 {
            columnKey = .between(columnKey, nil)
            let column = Block(pageId: source, kind: .column, sortKey: columnKey!, containerId: columnList.id, props: BlockProps(["widthRatio": .number(0.5)]))
            inner.append(column)
            inner.append(Block(pageId: source, kind: .paragraph, text: InlineText("В колонке \(number)"), sortKey: .between(nil, nil), containerId: column.id))
        }
        var tableKey: FractionalSortKey?
        for _ in 1...2 {
            tableKey = .between(tableKey, nil)
            let column = Block(pageId: source, kind: .tableColumn, sortKey: tableKey!, containerId: table.id, props: BlockProps(["width": .number(120)]))
            sample.tableColumns.append(column)
            inner.append(column)
        }
        for row in 1...2 {
            tableKey = .between(tableKey, nil)
            let rowBlock = Block(pageId: source, kind: .tableRow, sortKey: tableKey!, containerId: table.id)
            inner.append(rowBlock)
            var cellKey: FractionalSortKey?
            for (index, column) in sample.tableColumns.enumerated() {
                cellKey = .between(cellKey, nil)
                var props = BlockProps()
                props.columnId = column.id
                let cell = Block(pageId: source, kind: .tableCell, text: InlineText("\(row)×\(index + 1)"), sortKey: cellKey!, containerId: rowBlock.id, props: props)
                sample.cells.append(cell)
                inner.append(cell)
            }
        }
        sample.all = sample.roots + [sample.after] + inner
        return sample
    }

    @Test("Копия: новые id, контейнеры — на копии, ячейки — на копии столбцов; текст, цвет и props те же")
    func copiesWithNewIdsAndContainers() throws {
        let sample = sample()
        let copy = BlockCopier.copy(sample.roots, pageBlocks: sample.all, into: target)
        let originalIds = Set(sample.all.map(\.id))
        #expect(copy.blocks.count == 4 + 4 + 2 + 2 + 4, "4 блока потока, 2 колонки с блоками, 2 столбца, 2 строки, 4 ячейки")
        #expect(copy.blocks.allSatisfy { !originalIds.contains($0.id) && $0.pageId == target })
        #expect(Set(copy.blocks.map(\.id)).count == copy.blocks.count)
        #expect(copy.originals.map(\.id).sorted { $0.uuidString < $1.uuidString } == copy.newIds.keys.sorted { $0.uuidString < $1.uuidString })
        #expect(!copy.originals.contains { $0.id == sample.after.id }, "блок после выделенных не копируется")

        let byOriginal = Dictionary(uniqueKeysWithValues: copy.originals.map { original in
            (original.id, copy.blocks.first { $0.id == copy.newIds[original.id] }!)
        })
        for original in sample.all where original.id != sample.after.id {
            let copied = try #require(byOriginal[original.id])
            #expect(copied.kind == original.kind && copied.text == original.text && copied.color == original.color)
            #expect(copied.containerId == original.containerId.map { copy.newIds[$0]! }, "контейнер — копия контейнера")
            if original.kind == .tableCell {
                #expect(copied.props.columnId == copy.newIds[original.props.columnId!], "ячейка — на копии своего столбца")
                var withoutColumn = copied.props
                withoutColumn.columnId = original.props.columnId
                #expect(withoutColumn == original.props)
            } else {
                #expect(copied.props == original.props)
            }
            if original.containerId != nil { #expect(copied.sortKey == original.sortKey && copied.indent == original.indent) }
        }
    }

    @Test("Глубина — относительно первого; ключи потока — по порядку между заданными")
    func indentRelativeToFirstAndSequentialKeys() {
        let sample = sample()
        let after = FractionalSortKey.between(nil, nil)
        let copy = BlockCopier.copy(sample.roots, pageBlocks: sample.all, into: target, after: after)
        let flow = copy.blocks.filter { $0.containerId == nil }
        #expect(flow.map(\.indent) == [0, 1, 0, 1])
        #expect(flow.map(\.kind) == [.paragraph, .bulletItem, .columnList, .table])
        #expect(flow.allSatisfy { $0.sortKey > after })
        #expect(zip(flow, flow.dropFirst()).allSatisfy { $0.sortKey < $1.sortKey })
        let based = BlockCopier.copy(sample.roots, pageBlocks: sample.all, into: target, indentBase: 1)
        #expect(based.blocks.filter { $0.containerId == nil }.map(\.indent) == [1, 2, 1, 2])
    }

    @Test("movedFrom ставится у каждой копии по запросу — id исходного блока; без запроса — нет")
    func movedFromOnRequest() {
        let sample = sample()
        let moved = BlockCopier.copy(sample.roots, pageBlocks: sample.all, into: target, marksMovedFrom: true)
        for original in moved.originals {
            let copied = moved.blocks.first { $0.id == moved.newIds[original.id] }
            #expect(copied?.props.movedFrom == original.id)
        }
        let plain = BlockCopier.copy(sample.roots, pageBlocks: sample.all, into: target)
        #expect(plain.blocks.allSatisfy { $0.props.movedFrom == nil })
    }

    @Test("Копия перенесённого раньше блока без запроса — без movedFrom; с запросом — id нового исходного")
    func movedFromNotInherited() {
        let sample = sample()
        let moved = BlockCopier.copy(sample.roots, pageBlocks: sample.all, into: target, marksMovedFrom: true)
        let again = BlockCopier.copy(moved.blocks.filter { $0.containerId == nil }, pageBlocks: moved.blocks, into: source)
        #expect(again.blocks.count == moved.blocks.count)
        #expect(again.blocks.allSatisfy { $0.props.movedFrom == nil }, "Дубликат унаследовал пометку переноса")
        let movedAgain = BlockCopier.copy(moved.blocks.filter { $0.containerId == nil }, pageBlocks: moved.blocks, into: source,
                                          marksMovedFrom: true)
        for original in movedAgain.originals {
            #expect(movedAgain.blocks.first { $0.id == movedAgain.newIds[original.id] }?.props.movedFrom == original.id)
        }
    }

    @Test("movedFrom хранится в props ключом movedFrom")
    func movedFromKey() throws {
        var props = BlockProps()
        let id = UUID()
        props.movedFrom = id
        #expect(props.values["movedFrom"] == .string(id.uuidString.lowercased()))
    }
}
