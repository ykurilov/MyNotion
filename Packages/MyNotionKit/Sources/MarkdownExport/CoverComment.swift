import Foundation
import NotesCore

/// Обложка в выгрузке (contracts/sync-v3-and-export.md, «Выгрузка в Markdown»): строка сразу под названием.
/// `<!-- mynotion:cover gallery=gradients_3 offset=0.5 -->` или `<!-- mynotion:cover file="Обложка.jpg" offset=0.42 -->`.
enum CoverComment {
    /// `nil` — обложки нет или её картинка не выгружена (ещё не скачана).
    static func line(for cover: PageCover?, fileName: String?) -> String? {
        guard let cover else { return nil }
        let source: String
        switch cover.source {
        case .gallery(let id): source = "gallery=\(id)"
        case .file:
            guard let fileName else { return nil }
            source = "file=\"\(fileName.replacingOccurrences(of: "\"", with: "&quot;"))\""
        }
        return "<!-- mynotion:cover \(source) offset=\(offsetText(cover.offset)) -->"
    }

    /// 0.5, 0.42, 1 — без лишних нулей, не точнее четырёх знаков.
    static func offsetText(_ offset: Double) -> String {
        let rounded = (offset * 10_000).rounded() / 10_000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}
