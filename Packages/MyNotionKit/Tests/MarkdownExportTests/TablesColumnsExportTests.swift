import Foundation
import Testing
import NotesCore
@testable import MarkdownExport

/// Выгрузка таблиц и колонок (contracts/markdown-and-notion.md, «Блоки»): таблица — GFM, колонки — `<div data-columns>`.
@Suite("Таблицы и колонки в Markdown")
struct TablesColumnsExportTests {
    private let pageId = UUID()
    private let writer = MarkdownBlockWriter()

    private func paragraph(_ text: String, runs: [StyledRun] = [], in containerId: UUID? = nil, key: inout FractionalSortKey?) -> Block {
        key = .between(key, nil)
        return Block(pageId: pageId, text: InlineText(text, runs: runs), sortKey: key!, containerId: containerId)
    }

    /// Таблица из текстов ячеек; `nil` — ячейки нет.
    private func table(_ cells: [[String?]], headerRow: Bool = true, headerColumn: Bool = false, widths: [Double] = [],
                       runs: [String: [StyledRun]] = [:]) -> [Block] {
        var props = BlockProps.defaults(for: .table)
        props.hasHeaderRow = headerRow
        props.hasHeaderColumn = headerColumn
        let table = Block(pageId: pageId, kind: .table, sortKey: .between(nil, nil), props: props)
        let texts = cells.map { row in row.map { $0.map { InlineText($0, runs: runs[$0] ?? []) } ?? .empty } }
        // Пустые и отсутствующие ячейки — без блока, как у таблицы, где в них не писали.
        return [table] + TableGrid.contents(ofTable: table, cells: texts, widths: widths)
    }

    private func markdown(_ blocks: [Block]) -> String {
        writer.markdown(for: blocks, resolveLink: { _ in nil })
    }

    @Test("Таблица — GFM: первая строка — шапка; перед ней пометка с ширинами столбцов: загрузка вернёт их как были")
    func gfmTable() {
        let text = markdown(table([["Имя", "Роль"], ["Юрий", "автор"], ["Мишка", nil]]))
        #expect(text == """
            <!-- mynotion:table header-row="true" header-column="false" widths="120,120" -->
            | Имя | Роль |
            | --- | --- |
            | Юрий | автор |
            | Мишка |  |

            """)
    }

    @Test("В ячейке «|» экранируется, перенос — <br>, оформление — Markdown")
    func cellEscaping() {
        let text = markdown(table([["a | b", "две\nстроки"], ["жирный", ""]], runs: ["жирный": [StyledRun(start: 0, length: 6, style: .bold)]]))
        #expect(text == """
            <!-- mynotion:table header-row="true" header-column="false" widths="120,120" -->
            | a \\| b | две<br>строки |
            | --- | --- |
            | **жирный** |  |

            """)
    }

    @Test("Без строки заголовков или со столбцом заголовков — в пометке; ширины — всегда")
    func headerComment() {
        #expect(markdown(table([["a"]], headerRow: false)) == """
            <!-- mynotion:table header-row="false" header-column="false" widths="120" -->
            | a |
            | --- |

            """)
        #expect(markdown(table([["a", "b"]], headerColumn: true, widths: [120, 200])) == """
            <!-- mynotion:table header-row="true" header-column="true" widths="120,200" -->
            | a | b |
            | --- | --- |

            """)
    }

    @Test("Колонки — <div data-columns>, на колонку <div data-column data-width>, блоки Markdown между пустыми строками")
    func columns() {
        var key: FractionalSortKey?
        let before = paragraph("до", key: &key)
        let list = Block(pageId: pageId, kind: .columnList, sortKey: .between(before.sortKey, nil))
        let after = paragraph("после", key: &key)
        var left = Block(pageId: pageId, kind: .column, sortKey: .between(nil, nil), containerId: list.id)
        left.props.widthRatio = 0.3
        var right = Block(pageId: pageId, kind: .column, sortKey: .between(left.sortKey, nil), containerId: list.id)
        right.props.widthRatio = 0.7
        var inner: FractionalSortKey?
        let leftBlocks = [paragraph("левый", in: left.id, key: &inner)]
        inner = nil
        var bullet = paragraph("пункт", in: right.id, key: &inner)
        bullet.kind = .bulletItem
        let rightBlocks = [paragraph("правый", in: right.id, key: &inner), bullet]
        let text = markdown([before, list, after, left, right] + leftBlocks + rightBlocks)
        #expect(text == """
            до

            <div data-columns>
            <div data-column data-width="0.3">

            левый

            </div>
            <div data-column data-width="0.7">

            правый

            - пункт

            </div>
            </div>

            после

            """)
    }
}
