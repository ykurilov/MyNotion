import Foundation
import Synchronization
import Testing
@testable import Backlinks
@testable import NotesCore

/// Сигнал после фиксации записи: у каких страниц мог смениться счёт обратных ссылок. По нему открытая страница
/// перечитывает «↗ N» сразу, как в Notion; набор текста без ссылок сигнала не даёт.
@Suite("Сигнал смены обратных ссылок")
struct BacklinkChangeSignalTests {
    /// Сигналы подписчика по порядку.
    final class Signals: Sendable {
        private let received = Mutex<[BacklinkTargets]>([])
        func record(_ targets: BacklinkTargets) { received.withLock { $0.append(targets) } }
        func take() -> [BacklinkTargets] { received.withLock { all in defer { all.removeAll() }; return all } }
    }

    private static func library() throws -> (BacklinksLibrary, Signals) {
        let signals = Signals()
        return (try BacklinksLibrary(onLinksChange: { signals.record($0) }), signals)
    }

    @Test("Добавили упоминание — сигнал для страницы-цели; убрали — снова сигнал")
    func addAndRemoveMention() throws {
        let (library, signals) = try Self.library()
        let target = try library.page("Б")
        let source = try library.page("А")
        _ = signals.take()
        let block = try library.addMention(of: target.id, on: source.id)
        #expect(signals.take() == [.pages([target.id])])
        try library.eraseMention(in: block)
        #expect(signals.take() == [.pages([target.id])])
    }

    @Test("Упоминание заменено другим — сигнал для обеих страниц")
    func replacedMention() throws {
        let (library, signals) = try Self.library()
        let first = try library.page("Б")
        let second = try library.page("В")
        let source = try library.page("А")
        let block = try library.addMention(of: first.id, on: source.id)
        _ = signals.take()
        try library.store.write { transaction in
            var changed = try #require(try transaction.block(block.id))
            changed.text = BacklinksLibrary.text("Теперь ", mentioning: second.id)
            try transaction.updateBlock(changed)
        }
        #expect(signals.take() == [.pages([first.id, second.id])])
    }

    @Test("Набор текста в блоке без ссылок и в блоке с той же ссылкой сигнала не даёт")
    func typingIsSilent() throws {
        let (library, signals) = try Self.library()
        let target = try library.page("Б")
        let source = try library.page("А")
        let block = try library.addMention(of: target.id, on: source.id)
        _ = signals.take()
        try library.store.write { transaction in
            var changed = try #require(try transaction.block(block.id))
            changed.text = BacklinksLibrary.text("Смотри ещё ", mentioning: target.id)
            try transaction.updateBlock(changed)
            var plain = try #require(try transaction.blocks(ofPage: target.id).first)
            plain.text = InlineText("Просто текст")
            try transaction.updateBlock(plain)
        }
        #expect(signals.take().isEmpty)
    }

    @Test("Удалён блок со ссылкой — сигнал для цели")
    func deletedBlock() throws {
        let (library, signals) = try Self.library()
        let target = try library.page("Б")
        let source = try library.page("А")
        let link = try library.addPageLink(to: target.id, on: source.id)
        _ = signals.take()
        try library.deleteBlock(link.id)
        #expect(signals.take() == [.pages([target.id])])
    }

    @Test("Страница ушла в корзину, вернулась, стала шаблоном — сигнал «все страницы»")
    func trashAndTemplateTouchEverything() throws {
        let (library, signals) = try Self.library()
        let target = try library.page("Б")
        let source = try library.page("А")
        try library.addMention(of: target.id, on: source.id)
        _ = signals.take()
        try library.trash(source.id)
        #expect(signals.take() == [.all])
        try library.store.write { transaction in
            var page = try #require(try transaction.page(source.id))
            page.trashedAt = nil
            page.isTemplate = true
            try transaction.updatePage(page)
        }
        #expect(signals.take() == [.all])
    }

    @Test("Переименование страницы сигнала не даёт")
    func renameIsSilent() throws {
        let (library, signals) = try Self.library()
        let source = try library.page("А")
        _ = signals.take()
        try library.store.write { transaction in
            var page = try #require(try transaction.page(source.id))
            page.title = "А2"
            try transaction.updatePage(page)
        }
        #expect(signals.take().isEmpty)
    }

    @Test("Запись откатилась — сигнала нет")
    func rollbackIsSilent() throws {
        let (library, signals) = try Self.library()
        let target = try library.page("Б")
        let source = try library.page("А")
        _ = signals.take()
        struct Failure: Error {}
        #expect(throws: Failure.self) {
            try library.store.write { transaction in
                try transaction.insertBlock(Block(pageId: source.id, text: BacklinksLibrary.text("x", mentioning: target.id), sortKey: .between(nil, nil)))
                throw Failure()
            }
        }
        #expect(signals.take().isEmpty)
    }
}
