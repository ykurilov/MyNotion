import AppKit
import NotesCore
import PageEditor
import PageVersions

/// История версий открытой страницы (US6): «•••» → «История версий», восстановление с отменой и полосой после.
extension MainWindowModel {
    var versions: AppPageVersions { library.versions }

    /// Открыть историю: правки страницы — в базу и в свежую версию, чтобы первой строкой был текущий вид.
    /// Снимок пишет очередь записывателя, окно её не ждёт.
    func showVersionHistory(_ pageId: UUID) {
        openDocuments.saveAll()
        Task { @MainActor in
            do {
                try await versions.recorder.recordPending(pageId)
                guard let page = try store.pageContent(pageId)?.page else { return }
                versionHistory = try VersionHistoryModel(pageId: pageId, page: page, versions: versions.versions)
            } catch {
                showVersionError("Не удалось открыть историю версий: \(SaveStatus.reason(for: error))")
            }
        }
    }

    func closeVersionHistory() {
        versionHistory = nil
    }

    /// «Восстановить эту версию»: одна правка страницы с ⌘Z, вокруг неё — версии «до» и «после».
    func restoreVersion(_ versionId: UUID, ofPage pageId: UUID) {
        versionHistory = nil
        // Как у Notion: после восстановления каретки в странице нет — ни в перечитанной, ни в заново открытой.
        initialFocus = .unchanged
        openDocuments.saveAll()
        let restorer = VersionRestorer(recorder: versions.recorder, versions: versions.versions, operations: treeOperations)
        Task { @MainActor in
            do {
                try await restorer.restore(versionId: versionId, ofPage: pageId)
                restoredVersionPageId = pageId
                window?.makeFirstResponder(nil)
            } catch {
                showVersionError("Не удалось восстановить версию: \(SaveStatus.reason(for: error))")
            }
        }
    }

    /// Полоса «Страница восстановлена» — над страницей, которую восстановили, пока её не закроют.
    var showsRestoredBanner: Bool { restoredVersionPageId != nil && restoredVersionPageId == openPageId }

    /// Сообщение листом над окном: страница открыта, полоса ошибки окна не видна.
    private func showVersionError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window)
    }
}
