import Foundation
import Testing
@testable import NotesCore

/// Автосохранение (FR-014, research R4): правки копятся в памяти и пишутся через 300 мс
/// после последней, не реже раза в секунду при непрерывном наборе и сразу при уходе в фон и выходе.
@MainActor
@Suite("Автосохранение")
struct AutosaveCoordinatorTests {
    let folder: TemporaryFolder
    let wall = AdjustableWallClock(millis: 1_000)
    let store: NotesStore
    let scheduler = ManualAutosaveScheduler()
    let documents: OpenDocuments
    let pageId: UUID

    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(
            database: AppDatabase.open(at: folder.databaseURL),
            clock: HybridLogicalClock(deviceId: UUID(), wallClock: wall.reading)
        )
        pageId = try store.write { tx in
            let page = try tx.createPage(title: "Заметка")
            var first = try #require(try tx.blocks(ofPage: page.id).first)
            first.text = InlineText("первый")
            try tx.updateBlock(first)
            let second = try tx.insertBlock(Block(pageId: page.id, text: InlineText("второй"), sortKey: .between(first.sortKey, nil)))
            try tx.insertBlock(Block(pageId: page.id, kind: .checkbox, text: InlineText("третий"), sortKey: .between(second.sortKey, nil)))
            return page.id
        }
        documents = OpenDocuments(store: store, scheduler: scheduler)
    }

    private func storedBlocks() throws -> [Block] {
        try #require(try store.pageContent(pageId)).blocks
    }

    // MARK: Когда пишется

    @Test("Правка пишется через 300 мс после последнего нажатия, не раньше")
    func writesThreeHundredMillisecondsAfterLastEdit() throws {
        let document = try documents.open(pageId)
        let blockId = document.blocks[0].id

        document.setText(InlineText("пер"), ofBlock: blockId)
        scheduler.advance(by: .milliseconds(200))
        document.setText(InlineText("перв"), ofBlock: blockId)
        scheduler.advance(by: .milliseconds(299))
        #expect(try storedBlocks()[0].text.string == "первый")
        #expect(document.saveStatus == .saving)

        scheduler.advance(by: .milliseconds(1))
        #expect(try storedBlocks()[0].text.string == "перв")
        #expect(document.saveStatus == .saved)
        #expect(!document.hasUnsavedChanges)
    }

    @Test("Без правок ничего не пишется и ничего не запланировано")
    func nothingScheduledWithoutEdits() throws {
        let document = try documents.open(pageId)
        scheduler.advance(by: .seconds(5))
        #expect(scheduler.scheduledCount == 0)
        #expect(document.saveStatus == .saved)
    }

    @Test("Непрерывный набор пишется не реже раза в секунду (SC-005)")
    func continuousTypingIsWrittenAtLeastEverySecond() throws {
        let document = try documents.open(pageId)
        let blockId = document.blocks[1].id

        var typed = ""
        for step in 0..<5 {
            typed += "а"
            document.setText(InlineText(typed), ofBlock: blockId)
            scheduler.advance(by: .milliseconds(200))
            if step < 4 { #expect(try storedBlocks()[1].text.string == "второй") }
        }
        // Первая правка была в 0 мс, сейчас 1 000 мс: последняя набранная к этому моменту правка уже на диске.
        #expect(try storedBlocks()[1].text.string == "ааааа")
    }

    @Test("Уход в фон и выход пишут сразу, не дожидаясь 300 мс")
    func backgroundAndQuitWriteImmediately() throws {
        let document = try documents.open(pageId)
        let blockId = document.blocks[0].id

        document.setText(InlineText("в фон"), ofBlock: blockId)
        #expect(documents.saveAll())
        #expect(try storedBlocks()[0].text.string == "в фон")

        document.setTitle("Перед выходом")
        #expect(documents.saveAll())
        #expect(try store.pageContent(pageId)?.page.title == "Перед выходом")
        #expect(document.saveStatus == .saved)
    }

    @Test("Закрытие документа пишет несохранённое")
    func closingDocumentWrites() throws {
        let document = try documents.open(pageId)
        document.setText(InlineText("при закрытии"), ofBlock: document.blocks[2].id)
        documents.release(pageId)
        #expect(try storedBlocks()[2].text.string == "при закрытии")
    }

    // MARK: Один документ на страницу (R5)

    @Test("Все окна получают один и тот же документ страницы")
    func sameDocumentForEveryWindow() throws {
        let first = try documents.open(pageId)
        let second = try documents.open(pageId)
        #expect(first === second)

        documents.release(pageId)
        #expect(try documents.open(pageId) === first, "Пока документ открыт хоть в одном окне, он тот же")
        documents.release(pageId)
        documents.release(pageId)
        #expect(try documents.open(pageId) !== first, "Закрытый во всех окнах документ читается заново")
    }

    // MARK: Что пишется

    @Test("Пишутся только изменённые поля изменённых блоков")
    func writesOnlyChangedFieldsOfChangedBlocks() throws {
        let before = try storedBlocks()
        let pageBefore = try #require(try store.pageContent(pageId)).page
        let document = try documents.open(pageId)

        wall.set(50_000)
        document.setText(InlineText("второй, исправленный"), ofBlock: before[1].id)
        scheduler.advance(by: .milliseconds(300))

        let after = try storedBlocks()
        #expect(after[0] == before[0], "Нетронутый блок не перезаписан")
        #expect(after[2] == before[2], "Нетронутый блок не перезаписан")
        #expect(after[1].text.string == "второй, исправленный")
        #expect(after[1].fieldClocks.text?.wallMillis == 50_000)
        #expect(after[1].fieldClocks.kindAndIndent == before[1].fieldClocks.kindAndIndent)
        #expect(after[1].fieldClocks.isChecked == before[1].fieldClocks.isChecked)
        #expect(after[1].fieldClocks.sortKey == before[1].fieldClocks.sortKey)
        #expect(try store.pageContent(pageId)?.page == pageBefore, "Название не трогали — страница не перезаписана")
    }

    @Test("Поле, изменённое в базе другим источником, не откатывается правкой текста")
    func otherFieldsChangedInDatabaseSurvive() throws {
        let document = try documents.open(pageId)
        let checkboxId = document.blocks[2].id

        // Пока страница открыта, отметку ставит другой источник (например, синхронизация).
        try store.write { tx in
            var block = try #require(try tx.block(checkboxId))
            block.isChecked = true
            try tx.updateBlock(block)
        }

        document.setText(InlineText("третий, с текстом"), ofBlock: checkboxId)
        scheduler.advance(by: .milliseconds(300))

        let stored = try storedBlocks()[2]
        #expect(stored.isChecked, "Отметка из базы осталась")
        #expect(stored.text.string == "третий, с текстом")
    }

    @Test("Новые и удалённые блоки пишутся вместе с правкой")
    func insertedAndDeletedBlocksAreWritten() throws {
        let document = try documents.open(pageId)
        let ids = document.blocks.map(\.id)

        // Абзац «второй» удалён, после «первого» вставлен новый.
        let assigned = document.replaceBlocks(after: nil, before: ids[2], with: [
            BlockDraft(id: ids[0], text: InlineText("первый")),
            BlockDraft(id: nil, text: InlineText("вставленный")),
        ])
        scheduler.advance(by: .milliseconds(300))

        let stored = try storedBlocks()
        #expect(stored.map(\.text.string) == ["первый", "вставленный", "третий"])
        #expect(stored.map(\.id) == [ids[0], assigned[1], ids[2]])
        #expect(!stored.contains { $0.id == ids[1] })
    }

    // MARK: Конфликт (R4, R8)

    @Test("Если в базе текст блока новее начала правки — он не затирается, а создаётся конфликт")
    func newerTextInDatabaseBecomesConflict() throws {
        let document = try documents.open(pageId)
        let blockId = document.blocks[0].id

        wall.set(20_000)
        try store.write { tx in
            var block = try #require(try tx.block(blockId))
            block.text = InlineText("правка с другого Mac")
            try tx.updateBlock(block)
        }

        wall.set(30_000)
        document.setText(InlineText("правка здесь"), ofBlock: blockId)
        scheduler.advance(by: .milliseconds(300))

        #expect(try storedBlocks()[0].text.string == "правка с другого Mac", "Чужая версия не затёрта")
        let conflicts = try store.unresolvedConflicts(ofPage: pageId)
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.blockId == blockId)
        #expect(conflicts.first?.localVersion.string == "правка здесь")
        #expect(conflicts.first?.remoteVersion.string == "правка с другого Mac")
        #expect(document.blocks[0].text.string == "правка здесь", "В окне остаётся своя версия")
        #expect(document.saveStatus == .saved, "Обе версии на диске")

        // Следующая правка того же блока обновляет тот же конфликт, а не плодит новые.
        document.setText(InlineText("правка здесь, дописанная"), ofBlock: blockId)
        scheduler.advance(by: .milliseconds(300))
        let again = try store.unresolvedConflicts(ofPage: pageId)
        #expect(again.count == 1)
        #expect(again.first?.localVersion.string == "правка здесь, дописанная")
        #expect(try storedBlocks()[0].text.string == "правка с другого Mac")
    }
}
