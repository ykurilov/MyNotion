import Foundation

/// Опись галереи рядом со снимками: `manifest.json` для проверяющего агента и `index.html` для глаз.
public enum GalleryReport {
    public struct Entry: Codable, Hashable, Sendable {
        public let file: String
        public let state: String
        public let description: String
        public let section: String
        public let theme: GalleryTheme
        public let width: Int
        public let height: Int
    }

    public static func entries(for shots: [GalleryShot]) -> [Entry] {
        shots.map { shot in
            Entry(file: shot.fileName, state: shot.state.id, description: shot.state.summary, section: shot.state.section,
                  theme: shot.theme, width: shot.size.width, height: shot.size.height)
        }
    }

    public static func manifestJSON(for shots: [GalleryShot]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(entries(for: shots))
    }

    /// Сетка по разделам: в строке — светлая и тёмная тема одного состояния и размера.
    public static func indexHTML(for shots: [GalleryShot], missing: [String: String] = [:]) -> String {
        var html = """
        <!doctype html>
        <html lang="ru"><head><meta charset="utf-8"><title>MyNotion — галерея состояний</title>
        <style>
        body { font: 14px -apple-system, sans-serif; margin: 24px; background: #f6f5f4; color: #37352f; }
        h1 { font-size: 22px; } h2 { font-size: 18px; margin-top: 40px; border-bottom: 1px solid #ddd; padding-bottom: 6px; }
        .pair { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin: 20px 0 8px; }
        .caption { font-weight: 600; margin-top: 24px; } .caption code { font-weight: 400; color: #787774; }
        figure { margin: 0; } figcaption { color: #787774; font-size: 12px; margin-bottom: 4px; }
        img { width: 100%; border: 1px solid #ddd; border-radius: 6px; display: block; }
        .missing { color: #c4554d; }
        </style></head><body>
        <h1>MyNotion — галерея состояний</h1>
        <p>\(shots.count) снимков. В строке — светлая и тёмная тема одного состояния.</p>

        """
        var section: String?
        var rows: [(state: GalleryState, size: GalleryWindowSize)] = []
        for shot in shots where rows.last.map({ $0.state != shot.state || $0.size != shot.size }) ?? true {
            rows.append((shot.state, shot.size))
        }
        for row in rows {
            if row.state.section != section {
                section = row.state.section
                html += "<h2>\(escape(row.state.section))</h2>\n"
            }
            html += "<div class=\"caption\">\(escape(row.state.summary)) <code>\(row.state.id) · \(row.size.name)</code></div>\n"
            html += "<div class=\"pair\">\n"
            for theme in GalleryTheme.allCases {
                let file = GalleryShot(state: row.state, theme: theme, size: row.size).fileName
                html += "<figure><figcaption>\(theme.title)</figcaption>"
                if let reason = missing[file] {
                    html += "<p class=\"missing\">Не снято: \(escape(reason))</p>"
                } else {
                    html += "<a href=\"\(file)\"><img src=\"\(file)\" loading=\"lazy\" alt=\"\(escape(row.state.summary))\"></a>"
                }
                html += "</figure>\n"
            }
            html += "</div>\n"
        }
        html += "</body></html>\n"
        return html
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
