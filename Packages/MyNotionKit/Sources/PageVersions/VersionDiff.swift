import Foundation
import NotesCore

/// Что менялось в версии относительно прошлой (data-model.md, «page_version.summary»): список изменений у раскрытой версии.
public struct VersionSummary: Sendable, Hashable, Codable {
    /// Первая версия страницы — сравнивать не с чем.
    public var isFirst = false
    public var titleChanged = false
    public var iconChanged = false
    public var coverChanged = false
    /// Мелкий шрифт или широкая страница.
    public var layoutChanged = false
    public var blocksAdded = 0
    public var blocksRemoved = 0
    public var blocksChanged = 0
    /// Снимок «до правки агента» (005, research R5): имя агента, который сейчас начнёт править страницу.
    public var agent: String?

    public init(isFirst: Bool = false, titleChanged: Bool = false, iconChanged: Bool = false, coverChanged: Bool = false,
                layoutChanged: Bool = false, blocksAdded: Int = 0, blocksRemoved: Int = 0, blocksChanged: Int = 0, agent: String? = nil) {
        self.isFirst = isFirst
        self.titleChanged = titleChanged
        self.iconChanged = iconChanged
        self.coverChanged = coverChanged
        self.layoutChanged = layoutChanged
        self.blocksAdded = blocksAdded
        self.blocksRemoved = blocksRemoved
        self.blocksChanged = blocksChanged
        self.agent = agent
    }

    /// Строки списка изменений («изменено название», «добавлено 3 блока»).
    public var lines: [String] {
        guard let agent else { return changeLines }
        let changes = changeLines.filter { $0 != "без изменений" }
        return ["до правки агента (\(agent))"] + changes
    }

    private var changeLines: [String] {
        if isFirst { return ["первая версия"] }
        var lines: [String] = []
        if titleChanged { lines.append("изменено название") }
        if iconChanged { lines.append("изменена иконка") }
        if coverChanged { lines.append("изменена обложка") }
        if layoutChanged { lines.append("изменён вид страницы") }
        if blocksAdded > 0 { lines.append(Self.count(blocksAdded, one: "добавлен", many: "добавлено")) }
        if blocksRemoved > 0 { lines.append(Self.count(blocksRemoved, one: "удалён", many: "удалено")) }
        if blocksChanged > 0 { lines.append(Self.count(blocksChanged, one: "изменён", many: "изменено")) }
        return lines.isEmpty ? ["без изменений"] : lines
    }

    /// «добавлен 1 блок», «добавлено 3 блока», «добавлено 5 блоков», «добавлен 21 блок».
    static func count(_ number: Int, one: String, many: String) -> String {
        let lastTwo = number % 100, last = number % 10
        let isOne = last == 1 && lastTwo != 11
        let noun = isOne ? "блок" : (2...4).contains(last) && !(12...14).contains(lastTwo) ? "блока" : "блоков"
        return "\(isOne ? one : many) \(number) \(noun)"
    }

    private enum CodingKeys: String, CodingKey {
        case isFirst, titleChanged, iconChanged, coverChanged, layoutChanged, blocksAdded, blocksRemoved, blocksChanged, agent
    }

    /// Неизвестные и пропущенные ключи — по умолчанию: сводку могла записать другая версия приложения.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isFirst = try container.decodeIfPresent(Bool.self, forKey: .isFirst) ?? false
        titleChanged = try container.decodeIfPresent(Bool.self, forKey: .titleChanged) ?? false
        iconChanged = try container.decodeIfPresent(Bool.self, forKey: .iconChanged) ?? false
        coverChanged = try container.decodeIfPresent(Bool.self, forKey: .coverChanged) ?? false
        layoutChanged = try container.decodeIfPresent(Bool.self, forKey: .layoutChanged) ?? false
        blocksAdded = try container.decodeIfPresent(Int.self, forKey: .blocksAdded) ?? 0
        blocksRemoved = try container.decodeIfPresent(Int.self, forKey: .blocksRemoved) ?? 0
        blocksChanged = try container.decodeIfPresent(Int.self, forKey: .blocksChanged) ?? 0
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
    }
}

/// Разница двух снимков страницы: сводка версии и блоки для подсветки в просмотре.
public enum VersionDiff {
    public static func summary(from previous: PageSnapshot?, to current: PageSnapshot) -> VersionSummary {
        guard let previous else { return VersionSummary(isFirst: true) }
        var summary = VersionSummary()
        summary.titleChanged = previous.title != current.title
        summary.iconChanged = previous.icon != current.icon
        summary.coverChanged = previous.cover != current.cover
        summary.layoutChanged = previous.isFullWidth != current.isFullWidth || previous.isSmallText != current.isSmallText
        let before = Dictionary(previous.blocks.map { ($0.id, $0) }) { first, _ in first }
        let after = Set(current.blocks.map(\.id))
        for block in current.blocks {
            if let old = before[block.id] {
                if !old.hasSameContent(as: block) { summary.blocksChanged += 1 }
            } else {
                summary.blocksAdded += 1
            }
        }
        summary.blocksRemoved = before.keys.filter { !after.contains($0) }.count
        return summary
    }

    /// Блоки версии, которых нет в текущей странице или которые в ней другие, и их контейнеры в потоке страницы:
    /// подсветка в просмотре версии (вид контейнера — один знак текста страницы).
    public static func changedBlockIds(in version: PageSnapshot, comparedTo current: PageSnapshot) -> Set<UUID> {
        let currentById = Dictionary(current.blocks.map { ($0.id, $0) }) { first, _ in first }
        let blocks = version.blocks(onPage: UUID())
        var ids: Set<UUID> = []
        for block in version.blocks where !(currentById[block.id].map(block.hasSameContent) ?? false) {
            ids.insert(block.id)
            if block.containerId != nil, let root = pageFlowRoot(of: block.id, in: blocks) { ids.insert(root) }
        }
        return ids
    }

    /// Блок потока страницы, внутри которого лежит блок (у блока потока страницы — он сам).
    public static func pageFlowRoot(of blockId: UUID, in blocks: [Block]) -> UUID? {
        let byId = Dictionary(blocks.map { ($0.id, $0) }) { first, _ in first }
        var current = byId[blockId]
        var visited: Set<UUID> = []
        while let block = current, visited.insert(block.id).inserted {
            guard let containerId = block.containerId else { return block.id }
            current = byId[containerId]
        }
        return nil
    }
}
