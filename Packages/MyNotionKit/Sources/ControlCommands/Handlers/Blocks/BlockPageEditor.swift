import ControlProtocol
import Foundation
import NotesCore

/// Правка блоков страницы командой (FR-416): та же живая копия страницы, что в окне, поэтому окно видит правку сразу и не
/// теряет курсор. Порядок один: версия «до правки агента» → записать несохранённое → правка → записать на диск до ответа →
/// один шаг отмены. Отмена и повтор идут тем же путём, но в свою очередь записывают страницу.
@MainActor
struct BlockPageEditor {
    let session: CommandSession
    let pageId: UUID

    private var host: any ControlHost { session.host }

    /// Правка `body` над документом страницы. Ошибка внутри возвращает страницу, какой она была. Правка, ничего не
    /// изменившая, шага отмены не оставляет.
    @discardableResult
    func edit<T>(_ actionName: String, _ body: (PageDocument) throws -> T) async throws -> T {
        try await session.willWrite(pageId)
        try flush()
        let before = try storedBlocks()
        let document = try host.openDocuments.open(pageId)
        defer { host.openDocuments.release(pageId) }
        let result: T
        do {
            result = try body(document)
            try flush()
        } catch {
            restore(document, to: before)
            throw error
        }
        let after = try storedBlocks()
        let undo = BlockSnapshot.changes(from: after, to: before)
        guard !undo.isEmpty else { return result }
        BlockHistory.register(target: session.pageTree, host: HostBox(host: host), pageId: pageId, undo: undo,
                              redo: BlockSnapshot.changes(from: before, to: after), actionName: actionName)
        session.touch([pageId])
        host.treeDidChange([pageId])
        return result
    }

    /// Блоки страницы всех потоков, как записаны в базе.
    func storedBlocks() throws -> [Block] {
        do {
            guard let content = try host.store.pageContent(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            return content.blocks
        } catch {
            throw ControlError.wrapping(error)
        }
    }

    /// Всё, что окно ещё не записало, — на диск: дальше база и документ совпадают.
    private func flush() throws {
        guard host.openDocuments.saveAll() else {
            throw ControlError(.internal, "Не удалось записать страницу на диск", hint: "Проверьте свободное место и повторите команду")
        }
    }

    private func restore(_ document: PageDocument, to before: [Block]) {
        host.openDocuments.saveAll()
        guard let current = try? storedBlocks() else { return }
        document.apply(BlockSnapshot.rebased(BlockSnapshot.changes(from: current, to: before), onto: document))
        host.openDocuments.saveAll()
    }
}

/// Хост для замыкания отмены: оно живёт в `UndoManager` и не изолировано, а работает всегда на главном потоке.
struct HostBox: @unchecked Sendable {
    let host: any ControlHost
}

/// Разница между двумя состояниями блоков страницы: правка `PageDocument.apply`, переводящая одно в другое.
enum BlockSnapshot {
    static func changes(from old: [Block], to new: [Block]) -> BlockChanges {
        let oldById = Dictionary(old.map { ($0.id, $0) }) { first, _ in first }
        let newIds = Set(new.map(\.id))
        return BlockChanges(upserts: new.filter { block in oldById[block.id].map { !sameContent($0, block) } ?? true },
                            removals: old.map(\.id).filter { !newIds.contains($0) })
    }

    /// Совпадает всё, что пишет автосохранение (метки часов не в счёт).
    static func sameContent(_ lhs: Block, _ rhs: Block) -> Bool {
        lhs.kind == rhs.kind && lhs.text.normalized() == rhs.text.normalized() && lhs.indent == rhs.indent
            && lhs.isChecked == rhs.isChecked && lhs.linkedPageId == rhs.linkedPageId && lhs.sortKey == rhs.sortKey
            && lhs.containerId == rhs.containerId && lhs.color == rhs.color && lhs.props == rhs.props
    }

    /// Правка для записи поверх того, что в документе сейчас: блок в снимке несёт старую метку основы текста, и запись приняла бы
    /// возврат старого текста за столкновение с чужой правкой («Две версии»). Основа берётся у блока в документе.
    @MainActor
    static func rebased(_ changes: BlockChanges, onto document: PageDocument) -> BlockChanges {
        var result = changes
        result.upserts = changes.upserts.map { block in
            guard let current = document.block(block.id) else { return block }
            var block = block
            block.textBaseClock = current.textBaseClock
            return block
        }
        return result
    }

    /// Блоки потока контейнера (`nil` — страницы) по порядку.
    static func flow(_ blocks: [Block], of containerId: UUID?) -> [Block] {
        blocks.filter { $0.containerId == containerId }.sorted {
            $0.sortKey == $1.sortKey ? $0.id.uuidString < $1.id.uuidString : $0.sortKey < $1.sortKey
        }
    }
}

/// Шаги отмены правок блоков: каждый кладёт в `UndoManager` обратный себе.
@MainActor
enum BlockHistory {
    static func register(target: PageTreeOperations, host: HostBox, pageId: UUID, undo: BlockChanges, redo: BlockChanges, actionName: String) {
        guard let undoManager = target.undoManager else { return }
        undoManager.registerUndo(withTarget: target) { target in
            MainActor.assumeIsolated {
                let host = host.host
                guard let document = try? host.openDocuments.open(pageId) else { return }
                document.apply(BlockSnapshot.rebased(undo, onto: document))
                host.openDocuments.saveAll()
                host.openDocuments.release(pageId)
                host.treeDidChange([pageId])
                register(target: target, host: HostBox(host: host), pageId: pageId, undo: redo, redo: undo, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }
}
