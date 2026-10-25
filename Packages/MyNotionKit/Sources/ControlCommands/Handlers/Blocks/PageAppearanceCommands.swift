import ControlProtocol
import Foundation
import NotesCore
import PageCover

/// `page icon` и `page cover`: та же правка поля страницы, что в окне, — одна запись, один шаг отмены.
enum PageAppearanceCommands {
    // MARK: Иконка

    static let icon: CommandHandler = { session in
        let page = try session.page()
        let icon: String?
        if session.flag("remove") {
            icon = nil
        } else if let emoji = session.string("emoji") {
            guard isSingleEmoji(emoji) else {
                throw ControlError(.invalidValue, "Иконка — один эмодзи, а не «\(emoji)»", hint: "Пример: mynotion page icon current --emoji 🚀",
                                   details: ["argument": "emoji"])
            }
            icon = emoji
        } else {
            throw CommandCatalog.missing(named: "emoji", in: session.spec)
        }
        try await session.willWrite(page.id)
        do {
            try session.pageTree.setIcon(page.id, to: icon)
        } catch {
            throw ControlError.wrapping(error)
        }
        return CommandResult(["page": try session.storedPageJSON(page.id)],
                             text: icon.map { "✓ Иконка \($0) — «\(page.displayTitle)»" } ?? "✓ Иконка убрана — «\(page.displayTitle)»")
    }

    /// Один эмодзи, в том числе составной (семья, флаг, цифра в рамке): ровно один видимый знак.
    static func isSingleEmoji(_ text: String) -> Bool {
        guard text.count == 1, let first = text.unicodeScalars.first else { return false }
        let scalars = text.unicodeScalars
        let pictorial = scalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
        return pictorial || (first.properties.isEmoji && first.value > 0x7F)
    }

    // MARK: Обложка

    static let cover: CommandHandler = { session in
        if session.flag("list") {
            let items = CoverGallery.items.map { ControlJSON.object(["id": .string($0.id), "title": .string($0.title)]) }
            return CommandResult(["gallery": .array(items)], text: CoverGallery.items.map { "\($0.id) — \($0.title)" }.joined(separator: "\n"))
        }
        let page = session.args["page"] == nil
            ? try session.pageLocator.resolve("current", includeTrashed: session.includeTrashed) : try session.page()
        let offset = try offsetArgument(session)
        let change = try await coverChange(session, page: page, offset: offset)
        try await session.willWrite(page.id)
        do {
            switch change {
            case .set(let cover): try session.pageTree.setCover(page.id, to: cover)
            case .offset(let value): try session.pageTree.setCoverOffset(page.id, value)
            }
        } catch {
            throw ControlError.wrapping(error)
        }
        let text: String
        switch change {
        case .set(let cover): text = cover.map { _ in "✓ Обложка поставлена — «\(page.displayTitle)»" } ?? "✓ Обложка убрана — «\(page.displayTitle)»"
        case .offset(let value): text = "✓ Обложка сдвинута: \(value) — «\(page.displayTitle)»"
        }
        return CommandResult(["page": try session.storedPageJSON(page.id)], text: text)
    }

    private enum CoverChange {
        case set(PageCover?)
        case offset(Double)
    }

    @MainActor
    private static func offsetArgument(_ session: CommandSession) throws(ControlError) -> Double? {
        guard session.args["offset"] != nil else { return nil }
        guard let value = session.number("offset"), (0...1).contains(value) else {
            throw ControlError(.invalidValue, "--offset — число от 0 до 1 (0 — верх картинки, 1 — низ)", hint: "Пример: --offset 0.4",
                               details: ["argument": "offset"])
        }
        return value
    }

    /// Что сделать с обложкой; всё проверяется и готовится до записи, файл копируется в хранилище здесь.
    @MainActor
    private static func coverChange(_ session: CommandSession, page: Page, offset: Double?) async throws -> CoverChange {
        if session.flag("remove") { return .set(nil) }
        if let name = session.string("gallery") {
            let item = try galleryItem(named: name)
            return .set(PageCover(source: .gallery(item.id), offset: offset ?? PageCover.defaultOffset))
        }
        if let path = session.string("file") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw ControlError(.fileNotFound, "Нет файла \(url.path)", hint: "Укажите путь к картинке на этом Mac", details: ["path": .string(url.path)])
            }
            let operations = PageCoverOperations(tree: session.pageTree, attachments: session.host.attachments)
            do {
                let ref = try await operations.importCoverImage(from: url)
                return .set(PageCover(source: .file(ref), offset: offset ?? PageCover.defaultOffset))
            } catch let error as PageCoverError {
                throw ControlError(.invalidValue, error.localizedDescription, hint: "Нужна картинка (PNG, JPEG, HEIC…) до 100 МБ",
                                   details: ["argument": "file"])
            }
        }
        // Один сдвиг: у страницы должна быть обложка.
        guard let offset else { throw CommandCatalog.missing(named: "gallery", in: session.spec) }
        guard page.cover != nil else {
            throw ControlError(.invalidArgument, "У страницы «\(page.displayTitle)» нет обложки, сдвигать нечего",
                               hint: "Сначала поставьте: mynotion page cover current --gallery gradients_3", details: ["argument": "offset"])
        }
        return .offset(offset)
    }

    /// Плитка галереи по id или названию («solid_red», «Красный», «красный»).
    private static func galleryItem(named name: String) throws(ControlError) -> CoverGallery.Item {
        func folded(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let wanted = folded(name)
        if let item = CoverGallery.items.first(where: { folded($0.id) == wanted }) ?? CoverGallery.items.first(where: { folded($0.title) == wanted }) {
            return item
        }
        throw ControlError(.invalidValue, "В галерее нет обложки «\(name)»", hint: "Вся галерея: mynotion page cover --list",
                           details: ["argument": "gallery", "allowed": .array(CoverGallery.ids.map { .string($0) })])
    }
}
