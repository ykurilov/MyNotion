import Foundation
import NotesCore
import Observation
import PageEditor
import PageVersions

/// Окно «История версий» одной страницы (spec, US6; contracts/pages-ui.md, «История версий»): список с группировкой,
/// выбранная версия «только чтение» с подсветкой отличий от текущей, раскрытие со списком изменений, окно
/// «Что будет восстановлено». Самая новая версия — текущий вид страницы: её снимает открытие истории.
@MainActor
@Observable
final class VersionHistoryModel {
    let pageId: UUID
    let pageTitle: String
    /// Все версии, новые первыми; первая — текущая.
    private(set) var versions: [PageVersionInfo]
    var grouping: VersionGrouping = .minute {
        didSet { if !rows.contains(where: { $0.id == selectedId }), let first = rows.first { select(first.id) } }
    }
    private(set) var selectedId: UUID?
    /// «›» у выбранной версии: вместо списка — карточка версии и что менялось.
    var isExpanded = false
    var isRestoreDialogShown = false
    /// Что показать справа.
    private(set) var preview: Preview?
    private(set) var errorText: String?

    struct Preview {
        let versionId: UUID
        let document: PageDocument
        let highlightedBlockIds: Set<UUID>
    }

    @ObservationIgnored private let store: PageVersionStore
    @ObservationIgnored private let page: Page
    @ObservationIgnored private let current: PageSnapshot?

    init(pageId: UUID, page: Page, versions store: PageVersionStore) throws {
        self.pageId = pageId
        self.page = page
        self.store = store
        pageTitle = page.displayTitle
        let list = try store.versions(ofPage: pageId)
        versions = list
        current = try list.first.flatMap { try store.snapshot($0.id) }
        if let first = versions.first { select(first.id) }
    }

    var rows: [PageVersionInfo] { grouping.group(versions) }
    var currentVersionId: UUID? { versions.first?.id }
    var selected: PageVersionInfo? { versions.first { $0.id == selectedId } }
    var isCurrentSelected: Bool { selectedId != nil && selectedId == currentVersionId }

    func timeText(_ version: PageVersionInfo) -> String { VersionTimeText.text(for: version.createdAt) }

    /// Показать версию справа: документ из снимка (не сохраняется) и блоки, отличные от текущей страницы.
    func select(_ versionId: UUID) {
        guard versionId != preview?.versionId else { selectedId = versionId; return }
        selectedId = versionId
        do {
            guard let snapshot = try store.snapshot(versionId) else { throw VersionRestoreError.versionGone }
            let document = PageDocument(content: PageContent(page: snapshot.applied(to: page), blocks: snapshot.blocks(onPage: pageId),
                                                             removedContainers: [:]))
            let highlighted = current.map { VersionDiff.changedBlockIds(in: snapshot, comparedTo: $0) } ?? []
            preview = Preview(versionId: versionId, document: document, highlightedBlockIds: highlighted)
            errorText = nil
        } catch {
            preview = nil
            errorText = "Версию не прочитать: \(error.localizedDescription)"
        }
    }

    /// ↑ ↓ по списку.
    func selectNeighbour(_ offset: Int) {
        let rows = rows
        guard let index = rows.firstIndex(where: { $0.id == selectedId }) else { return }
        let next = min(max(index + offset, 0), rows.count - 1)
        select(rows[next].id)
    }
}
