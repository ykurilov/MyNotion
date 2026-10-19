import Foundation

/// Ссылка на ролик YouTube или Vimeo (research R8): блок «Видео» показывает обложку, а проигрыватель сайта
/// открывает только по нажатию «Играть».
public enum VideoLink: Sendable, Hashable {
    case youtube(id: String)
    case vimeo(id: String)

    public init?(url: URL) {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "youtu.be":
            guard let id = path.first, Self.isYouTubeId(id) else { return nil }
            self = .youtube(id: id)
        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "www.youtube-nocookie.com", "youtube-nocookie.com":
            let id: String?
            if path.first == "watch" {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            } else if path.count >= 2, ["shorts", "embed", "live", "v"].contains(path[0]) {
                id = path[1]
            } else {
                id = nil
            }
            guard let id, Self.isYouTubeId(id) else { return nil }
            self = .youtube(id: id)
        case "vimeo.com", "www.vimeo.com", "player.vimeo.com":
            guard let id = path.last, !id.isEmpty, id.allSatisfy(\.isASCIIDigit) else { return nil }
            self = .vimeo(id: id)
        default:
            return nil
        }
    }

    /// `youtube` или `vimeo` — как `props.source` блока.
    public var sourceName: String {
        switch self {
        case .youtube: "youtube"
        case .vimeo: "vimeo"
        }
    }

    /// Обычный адрес ролика — для выгрузки и «Открыть».
    public var watchURL: URL {
        switch self {
        case .youtube(let id): URL(string: "https://www.youtube.com/watch?v=\(id)")!
        case .vimeo(let id): URL(string: "https://vimeo.com/\(id)")!
        }
    }

    /// Страница встраивания для веб-проигрывателя; играет сразу — её открывает нажатие «Играть».
    public var embedURL: URL {
        switch self {
        case .youtube(let id): URL(string: "https://www.youtube-nocookie.com/embed/\(id)?autoplay=1")!
        case .vimeo(let id): URL(string: "https://player.vimeo.com/video/\(id)?autoplay=1")!
        }
    }

    /// Адрес встраивания без автозапуска — для выгрузки в Markdown.
    public var plainEmbedURL: URL {
        switch self {
        case .youtube(let id): URL(string: "https://www.youtube-nocookie.com/embed/\(id)")!
        case .vimeo(let id): URL(string: "https://player.vimeo.com/video/\(id)")!
        }
    }

    /// Один запрос при вставке даёт название и обложку.
    public var oEmbedURL: URL {
        let watch = watchURL.absoluteString.replacingOccurrences(of: "=", with: "%3D").replacingOccurrences(of: "&", with: "%26")
        switch self {
        case .youtube: return URL(string: "https://www.youtube.com/oembed?url=\(watch)&format=json")!
        case .vimeo: return URL(string: "https://vimeo.com/api/oembed.json?url=\(watch)")!
        }
    }

    private static func isYouTubeId(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
