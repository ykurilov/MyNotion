import AppKit
import Attachments
import EmbeddedMedia
import LinkPreview
import NotesCore
import NotionImport
import PageEditor
import UniformTypeIdentifiers

/// Службы медиа-блоков редактора (US5): копии файлов (`Attachments`), карточки и обложки (`LinkPreview`),
/// проигрыватели (`EmbeddedMedia`). Редактор знает их только через `MediaBlockServices` (plan.md, Structure Decision).
@MainActor
final class AppMediaServices: MediaBlockServices {
    let attachments: AttachmentStore
    let openDocuments: OpenDocuments
    let loader = LinkPreviewLoader()

    init(attachments: AttachmentStore, openDocuments: OpenDocuments) {
        self.attachments = attachments
        self.openDocuments = openDocuments
    }

    func availability(of ref: AttachmentRef) -> MediaAvailability {
        switch attachments.availability(of: ref.id) {
        case .ready(let url): .ready(url)
        case .downloading: .downloading
        case .waitingForOtherMac: .waitingForOtherMac
        case .failed(let message): .failed(message)
        }
    }

    func reserveFileImport(at url: URL) throws -> AttachmentRef {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try attachments.reserveFileImport(at: url)
    }

    /// Копирование большого файла — в фоне: окно не замирает, ход копирования — в `progress`. Готовое описание
    /// сразу ложится в блоки базы и открытых страниц: страницу могли закрыть, пока файл копировался.
    func importFile(at url: URL, into reserved: AttachmentRef, progress: @escaping @Sendable (Double) -> Void) async throws -> AttachmentRef {
        let attachments = attachments
        let ref = try await Task.detached(priority: .userInitiated) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            return try attachments.importFile(at: url, into: reserved, progress: progress)
        }.value
        // Не записалось — описание всё равно ляжет в блок открытой страницы через редактор.
        let pageIds = (try? attachments.placeInBlocks(ref)) ?? []
        openDocuments.applyExternalChanges(toPages: pageIds.intersection(openDocuments.openPageIds))
        return ref
    }

    func importData(_ data: Data, name: String, contentType: String) async throws -> AttachmentRef {
        let attachments = attachments
        return try await Task.detached(priority: .userInitiated) {
            try attachments.importData(data, name: name, contentType: contentType)
        }.value
    }

    func downloadFile(from url: URL) async throws -> AttachmentRef {
        let fetcher = URLSessionLinkFetcher(timeout: 120)
        let page: FetchedPage
        do {
            page = try await fetcher.fetchFile(url, byteLimit: AttachmentRef.maximumByteCount)
        } catch URLError.dataLengthExceedsMaximum {
            throw AttachmentError.tooLarge(name: url.lastPathComponent)
        } catch {
            throw DownloadError.failed
        }
        let name = url.lastPathComponent.isEmpty ? "Файл" : url.lastPathComponent
        let type = page.contentType.flatMap { UTType(mimeType: $0) } ?? UTType(filenameExtension: url.pathExtension) ?? .data
        let fileName = (name as NSString).pathExtension.isEmpty ? name + "." + (type.preferredFilenameExtension ?? "bin") : name
        return try await importData(page.data, name: fileName, contentType: type.identifier)
    }

    func videoSource(for url: URL) -> VideoSource? {
        switch VideoLink(url: url) {
        case .youtube: .youtube
        case .vimeo: .vimeo
        case nil: nil
        }
    }

    /// Карточка закладки: один запрос страницы, картинка и значок сайта — вложениями (уходят на другие Mac).
    func linkPreview(for url: URL) async -> MediaLinkPreview {
        let metadata = await loader.metadata(for: url)
        async let image = saveImage(metadata.imageURL, name: "Картинка сайта")
        async let icon = saveImage(metadata.iconURL, name: "Значок сайта")
        return MediaLinkPreview(title: metadata.title, description: metadata.summary, image: await image, icon: await icon)
    }

    /// Название и обложка ролика из oEmbed; обложка — вложением.
    func videoCover(for url: URL) async -> MediaLinkPreview? {
        guard let link = VideoLink(url: url), let info = await loader.videoInfo(for: link) else { return nil }
        let poster = await saveImage(info.thumbnailURL, name: "Обложка")
        return MediaLinkPreview(title: info.title, description: nil, image: poster, icon: nil)
    }

    func posterImage(forVideoAt url: URL) async -> NSImage? {
        await VideoPoster.image(forVideoAt: url)
    }

    func makePlayer(for block: Block, fileURL: URL?) -> NSView? {
        if let url = block.props.url, let link = VideoLink(url: url) {
            let player = WebVideoPlayerView(embedURL: link.embedURL)
            player.play()
            return player
        }
        guard let fileURL else { return nil }
        let player = VideoFilePlayerView(fileURL: fileURL)
        player.play()
        return player
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func saveImage(_ url: URL?, name: String) async -> AttachmentRef? {
        guard let url, let page = await loader.image(at: url) else { return nil }
        let type = page.contentType.flatMap { UTType(mimeType: $0) } ?? UTType(filenameExtension: url.pathExtension) ?? .png
        guard type.conforms(to: .image) else { return nil }
        return try? await importData(page.data, name: name + "." + (type.preferredFilenameExtension ?? "png"), contentType: type.identifier)
    }

    enum DownloadError: LocalizedError {
        case failed
        var errorDescription: String? { "Не получилось скачать файл по ссылке — проверьте адрес и интернет" }
    }
}

/// Импорт из Notion копирует картинки и файлы выгрузки во вложения.
extension AttachmentStore: @retroactive NotionAttachmentImporting {}

/// Очередь файлов изменилась (вставка, блок с другого Mac): будит отправку и докачку.
enum AttachmentQueueSignal {
    @MainActor static var handler: (() -> Void)?

    static func fire() {
        Task { @MainActor in handler?() }
    }
}
