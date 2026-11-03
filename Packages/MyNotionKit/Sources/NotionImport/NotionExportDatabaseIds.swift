import Foundation

extension PreparedNotionExport {
    /// Id баз Notion, которые лежат в выгрузке таблицами: по ним дочитывается схема. Без служебных копий `…_all.csv`.
    public func databaseIds() -> [String] {
        guard let paths = FileManager.default.subpaths(atPath: contentRoot.path) else { return [] }
        var found: [String] = []
        for path in paths.sorted() {
            let components = path.split(separator: "/")
            guard !components.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }),
                  path.lowercased().hasSuffix(".csv"), !path.lowercased().hasSuffix("_all.csv")
            else { continue }
            let stem = String(path.dropLast(".csv".count))
            if let id = NotionExportReader.notionId(in: stem), !found.contains(id) { found.append(id) }
        }
        return found
    }
}
