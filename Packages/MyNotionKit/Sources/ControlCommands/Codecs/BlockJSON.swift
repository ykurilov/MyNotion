import ControlProtocol
import Foundation
import NotesCore

/// Блок в ответах и на входе команд (contracts/block-json.md, «Блок»). `props` — как хранятся (`BlockProps`): ответ можно
/// отдать обратно без потерь.
public enum BlockJSON {
    /// Текст без оформления: Markdown не разбирается.
    static let plainTextKinds: Set<BlockKind> = [.code, .equation]

    public static func encode(_ block: Block, titles: MentionTitles, children: [ControlJSON]? = nil) -> ControlJSON {
        var object: [String: ControlJSON] = [
            "id": .string(block.id.controlText), "kind": .string(block.kind.rawValue),
            "text": .string(plainTextKinds.contains(block.kind) ? block.text.string : InlineMarkdownCodec.markdown(block.text, titles: titles)),
            "rich": RichTextJSON.encode(block.text), "indent": .number(Double(block.indent)), "checked": .bool(block.isChecked),
            "color": ["text": block.color.text.map { .string($0.rawValue) } ?? .null,
                      "background": block.color.background.map { .string($0.rawValue) } ?? .null],
            "props": .object(block.props.values.mapValues(\.control)),
            "linkedPageId": block.linkedPageId.map { .string($0.controlText) } ?? .null,
        ]
        if let children { object["children"] = .array(children) }
        return .object(object)
    }

    /// Блок из JSON. Нет `id` — новый; нет `props` — по умолчанию для вида. Текст — `rich` (точно) или `text` (Markdown).
    public static func decode(_ json: ControlJSON, pageId: UUID, sortKey: FractionalSortKey, containerId: UUID?) throws(ControlError) -> Block {
        guard let kindName = json["kind"]?.string, let kind = BlockKind(rawValue: kindName) else {
            throw ControlError(.invalidValue, "Неизвестный вид блока «\(json["kind"]?.string ?? "")»", hint: "Все виды: mynotion block kinds",
                               details: ["argument": "kind", "allowed": .array(BlockKind.allCases.map { .string($0.rawValue) })])
        }
        var id = UUID.timeOrdered()
        if let text = json["id"]?.string {
            guard let parsed = UUID(uuidString: text) else { throw invalid("id блока — UUID", argument: "id") }
            id = parsed
        }
        let indent = json["indent"]?.int ?? 0
        guard Block.indentRange.contains(indent) else {
            throw invalid("Отступ — от \(Block.indentRange.lowerBound) до \(Block.indentRange.upperBound)", argument: "indent")
        }
        var linkedPageId: UUID?
        if let text = json["linkedPageId"]?.string {
            guard let parsed = UUID(uuidString: text) else { throw invalid("linkedPageId — UUID страницы", argument: "linkedPageId") }
            linkedPageId = parsed
        }
        var props = BlockProps.defaults(for: kind)
        if let value = json["props"], !value.isNull {
            guard let object = value.object else { throw invalid("props — объект", argument: "props") }
            props = BlockProps(object.mapValues(\.core))
        }
        return Block(id: id, pageId: pageId, kind: kind, text: try text(of: json, kind: kind), indent: indent,
                     isChecked: json["checked"]?.bool ?? false, linkedPageId: linkedPageId, sortKey: sortKey, containerId: containerId,
                     color: try color(json["color"]), props: props)
    }

    private static func text(of json: ControlJSON, kind: BlockKind) throws(ControlError) -> InlineText {
        if let rich = json["rich"], !rich.isNull { return try RichTextJSON.decode(rich) }
        guard let markdown = json["text"]?.string else { return .empty }
        return plainTextKinds.contains(kind) ? InlineText(markdown) : InlineMarkdownCodec.inlineText(markdown)
    }

    static func color(_ json: ControlJSON?) throws(ControlError) -> BlockColor {
        guard let json, !json.isNull else { return .none }
        func one(_ key: String) throws(ControlError) -> NotionColor? {
            guard let value = json[key], !value.isNull, value.string != "default" else { return nil }
            guard let name = value.string, let color = NotionColor(rawValue: name) else {
                throw ControlError(.invalidValue, "Неизвестный цвет «\(value.string ?? value.encodedText())»",
                                   hint: "Цвета: " + (NotionColor.allCases.map(\.rawValue) + ["default"]).joined(separator: " "),
                                   details: ["argument": "color", "allowed": .array((NotionColor.allCases.map(\.rawValue) + ["default"]).map { .string($0) })])
            }
            return color
        }
        return BlockColor(text: try one("text"), background: try one("background"))
    }

    private static func invalid(_ message: String, argument: String) -> ControlError {
        ControlError(.invalidValue, message, hint: #"Пример: {"kind":"checkbox","text":"Купить **молоко**"}"#,
                     details: ["argument": .string(argument)])
    }
}
