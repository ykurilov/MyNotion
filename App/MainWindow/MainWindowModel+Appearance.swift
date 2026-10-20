import AppKit
import NotesCore
import PageCover

/// Обложка и вид страницы (US1): правки идут через `PageTreeOperations+Appearance` с отменой окна; открытый документ
/// подхватывает записанное (`PagesLibrary.appearanceDidChange`) без перечитывания страницы.
extension MainWindowModel {
    var coverOperations: PageCoverOperations {
        PageCoverOperations(tree: treeOperations, attachments: library.attachments)
    }

    func addRandomCover(_ pageId: UUID) {
        performAppearanceChange { try coverOperations.addRandomCover(to: pageId) }
    }

    func setGalleryCover(_ id: String, on pageId: UUID) {
        performAppearanceChange { try coverOperations.setGalleryCover(id, on: pageId) }
    }

    /// Своя картинка из «Загрузить» или перетаскивания из Finder: не картинка или больше 100 МБ — сообщение, обложка прежняя.
    func setImageCover(from url: URL, on pageId: UUID) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        performAppearanceChange { try coverOperations.setImageCover(from: url, on: pageId) }
    }

    func repositionCover(_ pageId: UUID, offset: Double) {
        performAppearanceChange { try coverOperations.reposition(pageId, offset: offset) }
    }

    func removeCover(_ pageId: UUID) {
        performAppearanceChange { try coverOperations.removeCover(from: pageId) }
    }

    func setSmallText(_ pageId: UUID, _ isOn: Bool) {
        performAppearanceChange { try treeOperations.setSmallText(pageId, isOn) }
    }

    func setFullWidth(_ pageId: UUID, _ isOn: Bool) {
        performAppearanceChange { try treeOperations.setFullWidth(pageId, isOn) }
    }

    /// Файл обложки на этом Mac; `nil` — ещё не пришёл с другого Mac.
    func coverFileURL(_ id: UUID) -> URL? {
        library.attachments.fileURL(for: id)
    }

    /// Сообщение листом над окном: страница открыта, и полоса ошибки окна (`loadError`) не видна.
    func showError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window)
    }

    private func performAppearanceChange(_ change: () throws -> Void) {
        // Набранное уходит в базу раньше правки: операция пишет страницу целиком.
        openDocuments.saveAll()
        do {
            try change()
        } catch let error as PageCoverError {
            showError(error.errorDescription ?? "Не удалось поставить обложку")
        } catch {
            showError("Не удалось изменить страницу: \(SaveStatus.reason(for: error))")
        }
    }
}

extension PagesLibrary {
    /// Обложку или вид сменили в обход документа: подставить записанное во все окна этой страницы.
    func appearanceDidChange(_ pageId: UUID) {
        guard let stored = try? store.pageOutline().first(where: { $0.id == pageId }) else { return }
        openDocuments.document(for: pageId)?.adoptAppearance(of: stored)
    }
}
