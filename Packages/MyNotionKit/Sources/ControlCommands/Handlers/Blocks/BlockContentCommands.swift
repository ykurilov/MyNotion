import ControlProtocol
import Foundation
import NotesCore

/// `block kinds`, `block get`, `block insert`, `block update` — что лежит в блоке и как его создать или поправить.
enum BlockContentCommands {
    static let kinds: CommandHandler = { _ in
        let lines = BlockKindCatalog.entries.map { "\($0.kind.rawValue) — \($0.summary)" }
        return CommandResult(["kinds": BlockKindCatalog.json], text: lines.joined(separator: "\n"))
    }

    static let get: CommandHandler = { session in
        // Что окно ещё не записало, — на диск: читаем то, что видит Юрий.
        session.host.openDocuments.saveAll()
        let block = try session.block()
        return CommandResult(try session.storedBlockJSON(block.id), text: "\(block.kind.rawValue): \(block.text.string)")
    }

    static let insert: CommandHandler = { session in
        let page = try session.page()
        let insertion = try BlockInsertion(session)
        let target = try BlockTarget.from(session, page: page)
        let pageId = try session.editablePage(page.id).id
        let id = try await BlockPageEditor(session: session, pageId: pageId).edit("Вставка блока") { document in
            try insertion.insert(into: document, target: target, session: session)
        }
        return CommandResult(try session.storedBlockJSON(id), text: "✓ Вставлен блок «\(insertion.kind.rawValue)»")
    }

    static let update: CommandHandler = { session in
        let block = try session.block()
        let pageId = try session.editablePage(of: block).id
        let update = try BlockUpdate(session, block: block)
        try await BlockPageEditor(session: session, pageId: pageId).edit("Изменение блока") { document in
            try update.apply(to: block.id, in: document)
        }
        return CommandResult(try session.storedBlockJSON(block.id), text: "✓ Блок изменён")
    }
}

/// Правка блока `block update`: новый текст, свойства, вид. Всё проверяется до правки страницы.
struct BlockUpdate {
    let kind: BlockKind?
    let text: InlineText?
    let props: [String: ControlJSON]

    @MainActor
    init(_ session: CommandSession, block: Block) throws(ControlError) {
        var kind: BlockKind?
        if let name = session.string("kind"), let target = BlockKind(rawValue: name) {
            guard BlockRules.turnable.contains(target), BlockRules.turnable.contains(block.kind) else {
                throw ControlError(.invalidArgument, "Блок вида «\(block.kind.rawValue)» нельзя превратить в «\(target.rawValue)»",
                                   hint: "Превращаются друг в друга: " + BlockRules.turnable.map(\.rawValue).joined(separator: ", "),
                                   details: ["argument": "kind", "kind": .string(block.kind.rawValue)])
            }
            kind = target
        }
        self.kind = kind
        let finalKind = kind ?? block.kind
        let hasText = session.args["text"] != nil || session.args["rich"] != nil
        text = try hasText ? BlockInsertion.text(session, kind: finalKind) : nil

        var props: [String: ControlJSON] = [:]
        if let value = session.args["props"], !value.isNull {
            guard let object = value.object else {
                throw ControlError(.invalidValue, "props — объект", hint: "Виды блоков и их свойства: mynotion block kinds",
                                   details: ["argument": "props"])
            }
            let sizes: Set<String> = finalKind == .table ? ["rows"] : finalKind == .columnList ? ["columns"] : []
            if let key = object.keys.sorted().first(where: sizes.contains) {
                throw ControlError(.invalidArgument, "Свойство «\(key)» задаётся только при вставке блока",
                                   hint: "Сделайте новый блок: mynotion block insert", details: ["argument": "props"])
            }
            props = object
        }
        self.props = props
    }

    /// Правка в живом документе: превращение идёт по правилам окна — выноска получает иконку, заголовок теряет недопустимую
    /// вложенность, снятая с задачи отметка стирается.
    @MainActor
    func apply(to id: UUID, in document: PageDocument) throws {
        guard let current = document.block(id) else { throw BlockRules.gone(id) }
        var updated = current
        if let kind, kind != current.kind {
            updated.kind = kind
            updated.props = BlockProps.defaults(for: kind)
            if current.color == .defaults(for: current.kind) { updated.color = .defaults(for: kind) }
            updated.isChecked = kind == .checkbox && current.isChecked
            if BlockJSON.plainTextKinds.contains(kind) { updated.text = InlineText(current.text.string) }
            if kind.isHeading {
                let (blocks, index, _) = try BlockRules.flow(of: current, in: document)
                updated.indent = BlockStructure.headingIndent(current.indent, at: index, in: blocks)
            }
        }
        if let text { updated.text = text }
        for (key, value) in props.sorted(by: { $0.key < $1.key }) {
            updated.props.values[key] = value.isNull ? nil : value.core
        }
        document.apply(BlockChanges(upserts: [updated]))
    }
}
