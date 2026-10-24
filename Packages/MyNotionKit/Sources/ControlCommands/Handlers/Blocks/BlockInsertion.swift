import ControlProtocol
import Foundation
import NotesCore

/// Новый блок из аргументов `block insert`: вид, текст, свойства. Всё проверяется до правки страницы; `insert` ставит
/// блок (а таблице, колонкам и подстранице — ещё и их содержимое) в живой документ, как это делает меню «/» в окне.
@MainActor
struct BlockInsertion {
    let kind: BlockKind
    let text: InlineText
    let props: BlockProps
    /// Таблица: ячейки по строкам; `nil` — пустая 2 × 3.
    let tableRows: [[InlineText]]?
    let columnCount: Int

    init(_ session: CommandSession) throws(ControlError) {
        guard let name = session.string("kind"), let kind = BlockKind(rawValue: name) else {
            throw CommandCatalog.missing(named: "kind", in: session.spec)
        }
        guard kind != .database else {
            throw ControlError(.invalidArgument, "Встроенная база вставляется не блоком, а командой db create",
                               hint: "Создать базу на странице: mynotion db create --help", details: ["argument": "kind"])
        }
        self.kind = kind
        text = try Self.text(session, kind: kind)

        var props = BlockProps.defaults(for: kind)
        var rows: [[InlineText]]?
        var columns = 2
        if let value = session.args["props"], !value.isNull {
            guard let object = value.object else { throw Self.invalid("props — объект", argument: "props") }
            for (key, item) in object.sorted(by: { $0.key < $1.key }) {
                switch (kind, key) {
                case (.table, "rows"): rows = try Self.rows(item)
                case (.columnList, "columns"):
                    guard let count = item.int, (2...ColumnLayout.maximumColumns).contains(count) else {
                        throw Self.invalid("columns — число колонок от 2 до \(ColumnLayout.maximumColumns)", argument: "props.columns")
                    }
                    columns = count
                default: props.values[key] = item.isNull ? nil : item.core
                }
            }
        }
        self.props = props
        tableRows = rows
        columnCount = columns
    }

    /// Текст блока: `--text` (Markdown строки; в коде и формуле — как есть) или `--rich` (точная разметка).
    static func text(_ session: CommandSession, kind: BlockKind) throws(ControlError) -> InlineText {
        let given = session.args["text"] != nil || session.args["rich"] != nil
        if given, BlockKindCatalog.textless.contains(kind) {
            throw ControlError(.invalidArgument, "У блока вида «\(kind.rawValue)» нет текста", hint: "Уберите --text и --rich",
                               details: ["argument": .string(session.args["rich"] != nil ? "rich" : "text")])
        }
        if let rich = session.args["rich"], !rich.isNull { return try RichTextJSON.decode(rich) }
        guard let markdown = session.string("text") else { return .empty }
        return BlockJSON.plainTextKinds.contains(kind) ? InlineText(markdown) : InlineMarkdownCodec.inlineText(markdown)
    }

    private static func rows(_ value: ControlJSON) throws(ControlError) -> [[InlineText]] {
        let shape = #"props.rows — список строк, строка — список ячеек: [["Имя","Возраст"],["Аня","7"]]"#
        guard let lines = value.array, !lines.isEmpty else { throw invalid(shape, argument: "props.rows") }
        var rows: [[InlineText]] = []
        for line in lines {
            guard let cells = line.array, !cells.isEmpty else { throw invalid(shape, argument: "props.rows") }
            rows.append(cells.map { cell in
                let text = cell.string ?? (cell.isNull ? "" : cell.encodedText())
                return InlineMarkdownCodec.inlineText(text)
            })
        }
        return rows
    }

    private static func invalid(_ message: String, argument: String) -> ControlError {
        ControlError(.invalidValue, message, hint: "Виды блоков и их свойства: mynotion block kinds", details: ["argument": .string(argument)])
    }

    /// Ставит блок на место `target`; возвращает id корня (у таблицы и колонок — самой таблицы и списка колонок).
    func insert(into document: PageDocument, target: BlockTarget, session: CommandSession) throws -> UUID {
        if kind == .pageLink { return try insertSubpageLink(into: document, target: target, session: session) }
        let placement = try target.place(in: document, kind: kind)
        let draft = BlockDraft(id: nil, kind: kind, text: text, indent: placement.indent, props: props)
        let ids = document.replaceBlocks(in: placement.containerId, after: placement.after, before: placement.before, with: [draft])
        guard let id = ids.first, let block = document.block(id) else {
            throw ControlError(.internal, "Блок не встал на страницу")
        }
        switch kind {
        case .table:
            let contents = tableRows.map { TableGrid.contents(ofTable: block, cells: $0) }
                ?? TableGrid.contents(ofNewTable: block, columns: 2, rows: 3)
            document.apply(BlockChanges(upserts: contents))
        case .columnList:
            document.apply(BlockChanges(upserts: columns(of: block)))
        default:
            break
        }
        return id
    }

    /// Колонки списка колонок, в каждой — пустой абзац: писать есть куда (как «/» → «Колонки»).
    private func columns(of list: Block) -> [Block] {
        var key: FractionalSortKey?
        return (0..<columnCount).flatMap { _ -> [Block] in
            key = .between(key, nil)
            let column = Block(pageId: list.pageId, kind: .column, sortKey: key!, containerId: list.id)
            return [column, Block(pageId: list.pageId, sortKey: .between(nil, nil), containerId: column.id)]
        }
    }

    /// Ссылка на подстраницу: страница и блок-ссылка рождаются парой в конце страницы (`createSubpage`), затем блок
    /// переезжает на своё место. Текст — название подстраницы.
    private func insertSubpageLink(into document: PageDocument, target: BlockTarget, session: CommandSession) throws -> UUID {
        let title = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let subpage = try session.pageTree.createSubpage(in: document.pageId, title: title)
        _ = session.host.openDocuments.applyExternalChanges(toPages: [document.pageId])
        guard let link = document.blocks.last(where: { $0.linkedPageId == subpage.id }) else {
            throw ControlError(.internal, "Ссылка на подстраницу не появилась на странице")
        }
        let placement = try target.place(in: document, excluding: [link.id], kind: .pageLink)
        document.apply(document.changesMoving([link.id], to: placement.containerId, after: placement.after, before: placement.before,
                                              rootIndent: placement.indent))
        return link.id
    }
}
