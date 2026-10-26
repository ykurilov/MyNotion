import Foundation
import NotionAPI

/// Буфер Notion в Chrome. Пустых блоков и картинок в HTML Notion нет (у картинки — только внутренняя ссылка
/// `attachment:…`); их места знает только буфер Chromium (`org.chromium.web-custom-data`), куда Notion кладёт
/// выделенные блоки JSON.
enum NotionClipboard {
    /// Верхний блок выделения.
    enum Entry: Equatable {
        /// Пустой текстовый блок.
        case empty
        /// Блок с текстом: в HTML у него свой верхний блок.
        case text(String)
        /// Картинка: откуда скачать (`notion-block:<id>` или адрес в сети) и имя файла.
        case image(URL, name: String)
    }

    /// Типы буфера Chromium с выделением Notion: блоки по порядку, у каждого — поддерево. Выделение текста кладёт их
    /// в `blockSelection.blocks`, выделение блоков (⌘A) — в `blocks` в корне.
    private static let selectionTypes = ["text/_notion-multi-text-production", "text/_notion-blocks-v3-production"]

    /// Блоки Notion с видео, звуком или файлом: в HTML буфера от них остаются только пропускаемые теги.
    private static let attachmentTypes: Set = ["video", "audio", "file", "pdf"]

    /// Верхние блоки выделения по порядку. `nil` — не Notion или данные не читаются.
    static func selectedBlocks(fromWebCustomData data: Data) -> [Entry]? {
        guard let pairs = webCustomData(data) else { return nil }
        for type in selectionTypes {
            guard let json = pairs[type], let blocks = selectedBlocks(fromJSON: json) else { continue }
            return blocks
        }
        return nil
    }

    private static func selectedBlocks(fromJSON json: String) -> [Entry]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let blocks = ((object["blockSelection"] as? [String: Any])?["blocks"] ?? object["blocks"]) as? [[String: Any]],
              !blocks.isEmpty else { return nil }
        var result: [Entry] = []
        for block in blocks {
            guard let subtree = block["blockSubtree"] as? [String: Any],
                  let records = subtree["block"] as? [String: [String: Any]],
                  let root = rootValue(of: records), let type = root["type"] as? String else { return nil }
            let properties = root["properties"] as? [String: Any]
            let title = text(ofTitle: properties?["title"])
            if type == "image" {
                // Картинка без id блока не скачается: пропускается, как раньше.
                if let image = image(root, source: text(ofTitle: properties?["source"]), title: title) { result.append(image) }
                continue
            }
            // Видео и файлов вставка из HTML не берёт (`PastedHTML` пропускает `video`…): со сверкой их не считаем.
            guard !attachmentTypes.contains(type) else { continue }
            if type == "text", title.isEmpty {
                result.append(.empty)
            } else if type == "text" {
                // Пустая строка внутри текстового блока (⇧↩ дважды) делит его в HTML на отдельные абзацы.
                let paragraphs = title.split(separator: /\n[ \t]*\n/).filter { !$0.allSatisfy(\.isWhitespace) }.map(String.init)
                result.append(contentsOf: (paragraphs.isEmpty ? [title] : paragraphs).map(Entry.text))
            } else {
                result.append(.text(title))
            }
        }
        return result
    }

    /// Картинка по адресу в сети скачивается прямо по нему, файл Notion (`attachment:<uuid>:<имя>`) — через API по id блока.
    /// Имя — подпись блока, иначе из `source` или адреса, иначе «Картинка».
    private static func image(_ value: [String: Any], source: String, title: String) -> Entry? {
        let web = URL(string: source).flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
        let fromSource = web.map(\.lastPathComponent)
            ?? (source.hasPrefix("attachment:") ? source.split(separator: ":", maxSplits: 2).dropFirst(2).first.map(String.init) : nil)
        let name = [title, fromSource ?? ""].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != "/" } ?? "Картинка"
        if let web { return .image(web, name: name) }
        guard let id = (value["id"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        return .image(NotionBlockLink.url(forBlock: id), name: name)
    }

    /// Верхний блок поддерева — тот, которого нет среди детей (`content`) других блоков.
    private static func rootValue(of records: [String: [String: Any]]) -> [String: Any]? {
        let values = records.compactMapValues { $0["value"] as? [String: Any] }
        let children = Set(values.values.flatMap { $0["content"] as? [String] ?? [] })
        let roots = values.filter { !children.contains($0.key) }
        return roots.count == 1 ? roots.first?.value : nil
    }

    /// Текст `title`: куски `[текст, оформление]` подряд.
    private static func text(ofTitle title: Any?) -> String {
        (title as? [[Any]] ?? []).compactMap { $0.first as? String }.joined()
    }

    /// Пары «тип — строка» буфера Chromium: размер, число пар, строки UTF-16LE с длиной в символах,
    /// каждая выровнена до 4 байт.
    private static func webCustomData(_ data: Data) -> [String: String]? {
        let bytes = [UInt8](data)
        var offset = 0
        func uint32() -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            defer { offset += 4 }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        func string() -> String? {
            guard let length = uint32(), offset + length * 2 <= bytes.count else { return nil }
            let units = (0..<length).map { UInt16(bytes[offset + $0 * 2]) | UInt16(bytes[offset + $0 * 2 + 1]) << 8 }
            offset += (length * 2 + 3) / 4 * 4
            return String(decoding: units, as: UTF16.self)
        }
        guard let size = uint32(), size + 4 <= bytes.count, let count = uint32() else { return nil }
        var pairs: [String: String] = [:]
        for _ in 0..<count {
            guard let type = string(), let value = string() else { return nil }
            pairs[type] = value
        }
        return pairs
    }
}
