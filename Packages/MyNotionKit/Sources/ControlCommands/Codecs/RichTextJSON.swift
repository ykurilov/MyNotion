import ControlProtocol
import Databases
import Foundation
import NotesCore

/// Точная разметка строки (contracts/block-json.md, `rich`): `{"string", "runs": [{"from", "to", "style"}]}`, смещения — UTF-16,
/// как в `InlineText`. Стиль — `bold`, `italic`, `strikethrough`, `code`, `underline`, `link:<адрес>`, `textColor:<цвет>`,
/// `backgroundColor:<цвет>`, `mention:<id>`, `date:<начало>` (полная дата — в `date` отрезка), `equation:<LaTeX>`.
public enum RichTextJSON {
    public static func encode(_ text: InlineText) -> ControlJSON {
        ["string": .string(text.string), "runs": .array(text.runs.map(encode))]
    }

    private static func encode(_ run: StyledRun) -> ControlJSON {
        var object: [String: ControlJSON] = ["from": .number(Double(run.start)), "to": .number(Double(run.start + run.length)),
                                             "style": .string(styleName(run.style))]
        if case .date(let date) = run.style, let json = try? JSONValue(encoding: date) { object["date"] = json.control }
        return .object(object)
    }

    static func styleName(_ style: InlineStyle) -> String {
        switch style {
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .code: "code"
        case .underline: "underline"
        case .link(let url): "link:" + url.absoluteString
        case .textColor(let color): "textColor:" + color.rawValue
        case .backgroundColor(let color): "backgroundColor:" + color.rawValue
        case .mention(let id): "mention:" + id.controlText
        case .date(let date): "date:" + date.start
        case .equation(let latex): "equation:" + latex
        }
    }

    public static func decode(_ json: ControlJSON) throws(ControlError) -> InlineText {
        guard let string = json["string"]?.string else {
            throw invalid("В `rich` нужен текст `string`")
        }
        let length = string.utf16.count
        var runs: [StyledRun] = []
        for (index, run) in (json["runs"]?.array ?? []).enumerated() {
            guard let from = run["from"]?.int, let to = run["to"]?.int, 0 <= from, from < to, to <= length else {
                throw invalid("Отрезок \(index + 1): `from` и `to` — целые, 0 ≤ from < to ≤ \(length) (UTF-16)")
            }
            guard let name = run["style"]?.string, let style = style(name, date: run["date"]) else {
                throw invalid("Отрезок \(index + 1): неизвестный стиль «\(run["style"]?.string ?? "")»")
            }
            runs.append(StyledRun(start: from, length: to - from, style: style))
        }
        return InlineText(string, runs: runs).normalized()
    }

    private static func style(_ name: String, date: ControlJSON?) -> InlineStyle? {
        switch name {
        case "bold": return .bold
        case "italic": return .italic
        case "strikethrough": return .strikethrough
        case "code": return .code
        case "underline": return .underline
        default: break
        }
        guard let colon = name.firstIndex(of: ":") else { return nil }
        let value = String(name[name.index(after: colon)...])
        switch name[..<colon] {
        case "link": return URL(string: value).map(InlineStyle.link)
        case "textColor": return NotionColor(rawValue: value).map(InlineStyle.textColor)
        case "backgroundColor": return NotionColor(rawValue: value).map(InlineStyle.backgroundColor)
        case "mention": return UUID(uuidString: value).map(InlineStyle.mention)
        case "equation": return .equation(value)
        case "date":
            if let full = try? date?.core.decoded(as: DateMention.self) { return .date(full) }
            guard DateParts(text: value) != nil else { return nil }
            return .date(DateMention(start: value, includesTime: value.contains("T"), timeZone: TimeZone.current.identifier))
        default: return nil
        }
    }

    private static func invalid(_ message: String) -> ControlError {
        ControlError(.invalidValue, message, hint: #"Пример: {"string":"Купить молоко","runs":[{"from":7,"to":13,"style":"bold"}]}"#,
                     details: ["argument": "rich"])
    }
}
