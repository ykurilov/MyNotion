import Foundation

/// Буфер Notion в Chrome. Пустых блоков в HTML Notion нет вовсе; их места знает только буфер Chromium
/// (`org.chromium.web-custom-data`), куда Notion кладёт выделенные блоки JSON.
enum NotionClipboard {
    /// Типы буфера Chromium с выделением Notion: `blockSelection.blocks` — блоки по порядку, у каждого — поддерево.
    private static let selectionTypes = ["text/_notion-multi-text-production", "text/_notion-blocks-v3-production"]

    /// Верхние блоки выделения по порядку: `nil` — пустой текстовый блок, иначе текст блока.
    /// `nil` целиком — не Notion или данные не читаются.
    static func selectedBlocks(fromWebCustomData data: Data) -> [String?]? {
        guard let pairs = webCustomData(data) else { return nil }
        for type in selectionTypes {
            guard let json = pairs[type], let blocks = selectedBlocks(fromJSON: json) else { continue }
            return blocks
        }
        return nil
    }

    private static func selectedBlocks(fromJSON json: String) -> [String?]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let selection = object["blockSelection"] as? [String: Any],
              let blocks = selection["blocks"] as? [[String: Any]], !blocks.isEmpty else { return nil }
        var result: [String?] = []
        for block in blocks {
            guard let subtree = block["blockSubtree"] as? [String: Any],
                  let records = subtree["block"] as? [String: [String: Any]],
                  let root = rootValue(of: records), let type = root["type"] as? String else { return nil }
            let title = text(ofTitle: (root["properties"] as? [String: Any])?["title"])
            result.append(type == "text" && title.isEmpty ? nil : title)
        }
        return result
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
