import Foundation
import NotesCore

/// Образец истории (quickstart.md, «Эталон»: 200 версий у «богатой» страницы) и страница «Замер: история версий» для
/// UI-теста и галереи. Версии — правки по одному блоку назад во времени: последние 60 — каждую минуту, затем каждые
/// 15 минут, затем каждый час; самая новая совпадает со страницей. Страница с версиями не трогается.
public enum PageVersionsSample {
    public static let pageTitle = "Замер: история версий"
    public static let versionCount = 200

    /// Страница образца (30 абзацев) с историей; id страницы.
    @discardableResult
    public static func ensure(in store: NotesStore, versions: PageVersionStore, deviceName: String, now: Date = Date()) throws -> UUID {
        let pageId: UUID
        if let existing = try store.pageOutline().first(where: { $0.title == pageTitle && $0.trashedAt == nil }) {
            pageId = existing.id
        } else {
            pageId = try store.write { tx in
                let page = try tx.createPage(title: pageTitle, icon: "🕘")
                for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
                var key: FractionalSortKey?
                for index in 0..<30 {
                    key = .between(key, nil)
                    try tx.insertBlock(Block(pageId: page.id, kind: index % 10 == 0 ? .heading2 : .paragraph,
                                             text: InlineText("Абзац \(index + 1): текст для истории версий."), sortKey: key!))
                }
                return page.id
            }
        }
        try addHistory(toPage: pageId, in: store, versions: versions, deviceName: deviceName, now: now)
        return pageId
    }

    /// 200 версий страницы, если у неё ещё нет ни одной.
    public static func addHistory(toPage pageId: UUID, in store: NotesStore, versions: PageVersionStore, deviceName: String,
                                  now: Date = Date()) throws {
        guard try versions.versions(ofPage: pageId).isEmpty, let content = try store.pageContent(pageId) else { return }
        let textual = content.blocks.indices.filter { !content.blocks[$0].kind.rendersAsAttachment && content.blocks[$0].containerId == nil }
        var blocks = content.blocks
        var snapshots: [(Date, PageSnapshot)] = []
        // От новой к старой: каждая следующая (старее) отличается правкой одного блока.
        for step in 0..<versionCount {
            snapshots.append((date(ofStep: step, now: now), PageSnapshot(page: content.page, blocks: blocks)))
            guard !textual.isEmpty else { continue }
            let index = textual[step % textual.count]
            blocks[index].text = InlineText(blocks[index].text.string + " (\(step + 1))")
        }
        var previous: PageSnapshot?
        for (createdAt, snapshot) in snapshots.reversed() {
            try versions.save(snapshot, pageId: pageId, createdAt: createdAt, deviceName: deviceName,
                              summary: VersionDiff.summary(from: previous, to: snapshot))
            previous = snapshot
        }
        try versions.clearDue(pageId: pageId, upTo: now)
    }

    static func date(ofStep step: Int, now: Date) -> Date {
        let minutes: Int
        switch step {
        case ..<60: minutes = step + 1
        case ..<120: minutes = 60 + (step - 59) * 15
        default: minutes = 60 + 60 * 15 + (step - 119) * 60
        }
        return now.addingTimeInterval(-Double(minutes) * 60)
    }
}
