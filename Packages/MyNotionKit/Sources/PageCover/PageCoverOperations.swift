import Attachments
import Foundation
import NotesCore
import UniformTypeIdentifiers

/// Своя картинка не подошла (contracts/page-operations.md, «Обложка»): обложка остаётся прежней.
public enum PageCoverError: Error, Equatable, LocalizedError {
    case notImage(name: String)
    case tooLarge(name: String)

    public var errorDescription: String? {
        switch self {
        case .notImage(let name): "«\(name)» — не картинка"
        case .tooLarge: "Картинка больше 100 МБ — MyNotion такие не хранит"
        }
    }
}

/// Действия с обложкой из шапки и окна «Сменить обложку»: галерея, случайная, своя картинка, сдвиг, убрать.
/// Каждое — одна правка поля `cover` с отменой (`PageTreeOperations.setCover`); своя картинка сначала копируется
/// в хранилище файлов 002 и уходит на другие Mac, как картинка в тексте.
@MainActor
public final class PageCoverOperations {
    let tree: PageTreeOperations
    let attachments: AttachmentStore

    public init(tree: PageTreeOperations, attachments: AttachmentStore) {
        self.tree = tree
        self.attachments = attachments
    }

    /// «Добавить обложку»: случайная из галереи «Цвета и градиенты».
    public func addRandomCover(to pageId: UUID, using generator: inout some RandomNumberGenerator) throws {
        try setGalleryCover(CoverGallery.random(using: &generator).id, on: pageId)
    }

    public func addRandomCover(to pageId: UUID) throws {
        var generator = SystemRandomNumberGenerator()
        try addRandomCover(to: pageId, using: &generator)
    }

    public func setGalleryCover(_ id: String, on pageId: UUID) throws {
        try tree.setCover(pageId, to: PageCover(source: .gallery(id)))
    }

    /// «Загрузить»: картинка из Finder (выбор файла или перетаскивание). Не картинка или больше 100 МБ — ошибка
    /// до копирования, обложка прежняя. Копия — вне главного потока, как вставка файла 002 (`progress` — доля
    /// скопированного, зовётся с очереди копии); обложка — одной правкой с отменой, когда копия готова.
    public func setImageCover(from url: URL, on pageId: UUID, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let ref = try await importCoverImage(from: url, progress: progress)
        try setFileCover(ref, on: pageId)
    }

    /// Проверка и копия картинки обложки в хранилище файлов 002 — вне главного потока; обложку не меняет.
    public func importCoverImage(from url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> AttachmentRef {
        let name = url.lastPathComponent
        let attachments = attachments
        return try await Task.detached(priority: .userInitiated) {
            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
            let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
            guard let type, type.conforms(to: .image) else { throw PageCoverError.notImage(name: name) }
            guard (values?.fileSize ?? 0) <= AttachmentRef.maximumByteCount else { throw PageCoverError.tooLarge(name: name) }
            do {
                return try attachments.importFile(at: url, into: attachments.reserveFileImport(at: url), progress: progress)
            } catch AttachmentError.tooLarge {
                throw PageCoverError.tooLarge(name: name)
            }
        }.value
    }

    /// Обложка — уже скопированная картинка.
    public func setFileCover(_ ref: AttachmentRef, on pageId: UUID) throws {
        try tree.setCover(pageId, to: PageCover(source: .file(ref)))
    }

    /// «Сохранить положение» режима «Переместить».
    public func reposition(_ pageId: UUID, offset: Double) throws {
        try tree.setCoverOffset(pageId, offset)
    }

    /// «Убрать»: файл картинки остаётся, пока на него есть ссылки (002).
    public func removeCover(from pageId: UUID) throws {
        try tree.setCover(pageId, to: nil)
    }
}
