import AppKit
import Databases
import NotesCore
import PagePicker
import VisualStyle

/// Копии (US4): «Дублировать» и «Переместить в» страницы и блоков. Операции — `PageTreeOperations+Duplicate`
/// и `+MoveBlocks` с отменой окна; окно выбора страницы — `PagePickerController`.
extension MainWindowModel {
    /// Копия ветки пишется с очереди записи; по готовности открывается в текущей вкладке (contracts/page-operations.md).
    func duplicatePage(_ pageId: UUID) {
        // Набранное уходит в базу раньше копии: копия читает страницу из базы.
        openDocuments.saveAll()
        // ⇧⌘Z дописывает копию с очереди записи — по готовности она открывается, как после «Дублировать».
        treeOperations.onDuplicateRedone = { [weak self] copy in self?.navigate(to: copy.id, focus: .unchanged) }
        Task {
            do {
                let copy = try await treeOperations.duplicate(pageId)
                navigate(to: copy.id, focus: .unchanged)
            } catch {
                showError("Не удалось дублировать страницу: \(SaveStatus.reason(for: error))")
            }
        }
    }

    /// «Переместить в» страницы: внутрь выбранной в конец её подстраниц или на верхний уровень.
    /// `anchor` — место меню на экране; `nil` — у верхней полосы справа (⇧⌘P, меню «•••»).
    func showMovePagePicker(_ pageId: UUID, anchor: NSRect? = nil) {
        showMovePicker(.page(pageId), anchor: anchor) { [weak self] target in
            let parentId: UUID? = if case .page(let id) = target { id } else { nil }
            self?.confirmRowLeavingDatabase(pageId, to: parentId) { self?.move(pageId, toParent: parentId, at: .max) }
        }
    }

    /// Строка базы уходит в обычную страницу — её свойства пропадут из вида (spec, Edge Cases): спросить. ⌘Z вернёт всё.
    private func confirmRowLeavingDatabase(_ pageId: UUID, to parentId: UUID?, then move: @escaping () -> Void) {
        guard let window, (try? DatabaseTreeAddon.movingLosesProperties(pageId, to: parentId, in: store)) == true else { return move() }
        let alert = NSAlert()
        alert.messageText = "Перенести строку из базы?"
        alert.informativeText = "Страница перестанет быть строкой базы, и её свойства пропадут. Вернуть всё можно через ⌘Z."
        alert.addButton(withTitle: "Перенести")
        alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { move() }
        }
    }

    /// «Переместить в» блоков: в конец выбранной страницы; исходная остаётся открытой.
    func showMoveBlocksPicker(_ blockIds: [UUID], from pageId: UUID, anchor: NSRect?) {
        showMovePicker(.blocks(fromPage: pageId), anchor: anchor) { [weak self] target in
            guard let self, case .page(let targetId) = target else { return }
            openDocuments.saveAll()
            do {
                try treeOperations.moveBlocks(blockIds, from: pageId, to: targetId)
            } catch {
                showError("Не удалось перенести блоки: \(SaveStatus.reason(for: error))")
            }
        }
    }

    private func showMovePicker(_ subject: PagePickerSubject, anchor: NSRect?, onChoose: @escaping (PagePickerTarget) -> Void) {
        guard let window else { return }
        openDocuments.saveAll()
        movePicker.show(subject, store: store, tree: tree, below: anchor ?? Self.topBarAnchor(of: window), in: window,
                        onChoose: onChoose)
    }

    /// Правый край верхней полосы окна, под ней — как окно «Move page to…» у Notion от «•••».
    static func topBarAnchor(of window: NSWindow) -> NSRect {
        let frame = window.frame
        return NSRect(x: frame.maxX - 8, y: frame.maxY - Metrics.Window.titleBarHeight - Metrics.Page.topBarHeight + 8, width: 0, height: 0)
    }
}
