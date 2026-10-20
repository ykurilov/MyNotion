import AppKit
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
            switch target {
            case .page(let parentId): self?.move(pageId, toParent: parentId, at: .max)
            case .topLevel: self?.move(pageId, toParent: nil, at: .max)
            }
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
