import AppKit
import NotesCore
import PageEditor
import PageVersions
import XCTest

/// Замеры US6 (T088, quickstart.md): история и показ версии «богатой» страницы 1 000 блоков ≤ 0,5 с, восстановление ≤ 1 с
/// (SC-205); набор p95 ≤ 50 мс, пока пишутся версии (SC-203); место 200 версий «богатой» страницы — цифра.
@MainActor
final class VersionHistoryPerformanceTests: XCTestCase {
    static let showBudgetMs = 500.0
    static let restoreBudgetMs = 1_000.0
    static let typingBudgetMs = 50.0

    func testHistoryRestoreAndTypingWhileRecording() async throws {
        let page = try RichProbePage()
        defer { page.close() }
        try await page.settle()
        let versions = PageVersionStore(store: page.store)

        // Место: 200 версий «богатой» страницы.
        let historyMs = try ProbeEditor.measure {
            try PageVersionsSample.addHistory(toPage: page.pageId, in: page.store, versions: versions, deviceName: "Mac")
        }
        let bytes = try versions.byteCount(ofPage: page.pageId)
        let list = try versions.versions(ofPage: page.pageId)
        XCTAssertEqual(list.count, PageVersionsSample.versionCount)

        // Открытие истории и показ старой версии: список, снимки текущей и выбранной, разница, редактор «только чтение».
        let recorder = PageVersionRecorder(store: page.store, versions: versions)
        var showMs: [Double] = []
        for round in 0..<3 {
            var preview: (NSScrollView, VersionPreviewTextView)?
            showMs.append(try await ProbeEditor.measureAsync {
                try await recorder.recordPending(page.pageId)
                let all = try versions.versions(ofPage: page.pageId)
                let current = try XCTUnwrap(try versions.snapshot(all[0].id))
                let selected = try XCTUnwrap(try versions.snapshot(all[50 + round * 40].id))
                let highlighted = VersionDiff.changedBlockIds(in: selected, comparedTo: current)
                let content = try XCTUnwrap(try page.store.pageContent(page.pageId))
                let document = PageDocument(content: PageContent(page: selected.applied(to: content.page),
                                                                 blocks: selected.blocks(onPage: page.pageId), removedContainers: [:]))
                let editor = VersionPreviewTextView(document: document, initialFocus: .unchanged)
                editor.isEditable = false
                editor.highlightedBlockIds = highlighted
                let scroll = NSScrollView(frame: page.window.contentView!.frame)
                scroll.hasVerticalScroller = true
                scroll.documentView = editor
                editor.frame.size.width = scroll.contentSize.width
                page.window.contentView!.superview!.addSubview(scroll, positioned: .above, relativeTo: page.window.contentView)
                page.window.displayIfNeeded()
                preview = (scroll, editor)
            })
            if round == 0, let bitmap = page.snapshot() {
                _ = page.save(bitmap, name: "version-history-preview", to: self)
            }
            preview?.0.removeFromSuperview()
            preview = nil
            try await page.settle(100)
        }

        // Восстановление старой версии: снимок «до», правка страницы одной транзакцией, снимок «после».
        let operations = PageTreeOperations(store: page.store)
        let restorer = VersionRestorer(recorder: recorder, versions: versions, operations: operations)
        let target = try versions.versions(ofPage: page.pageId)[150].id
        let restoreMs = try await ProbeEditor.measureAsync { try await restorer.restore(versionId: target, ofPage: page.pageId) }

        // Набор, пока пишутся версии: записыватель с короткими сроками снимает страницу снова и снова.
        let documents = OpenDocuments(store: page.store)
        page.show(PageTextView(document: try documents.open(page.pageId), initialFocus: .unchanged))
        try await page.settle()
        defer { documents.release(page.pageId) }
        let busyRecorder = PageVersionRecorder(store: page.store, versions: versions, timing: .init(minimumInterval: 0.2, quietPeriod: 0))
        busyRecorder.installDueMarker(localDeviceName: "Mac")
        let recorded = RecordedCount()
        busyRecorder.onRecorded = { _ in recorded.increment() }
        busyRecorder.start()
        let paragraph = try XCTUnwrap(page.blockIndex(of: .paragraph))
        page.scroll(toBlock: paragraph)
        page.textView.setSelectedRange(NSRange(location: page.location(ofBlock: paragraph), length: 0))
        try await page.settle()
        var typing: [Double] = []
        let characters = Array("набор во время записи версий ")
        for index in 0..<150 {
            typing.append(ProbeEditor.measure {
                page.textView.insertText(String(characters[index % characters.count]), replacementRange: NSRange(location: NSNotFound, length: 0))
                page.window.displayIfNeeded()
            })
            if index % 10 == 0 { documents.saveAll() }
            try await Task.sleep(for: .milliseconds(20))
        }

        let summary = [
            "Версии: 200 версий «богатой» страницы — \(bytes / 1024) КБ (\(bytes / max(list.count, 1) / 1024) КБ на версию), запись образца \(ProbeEditor.format(historyMs)) мс",
            "Версии: открытие истории и показ версии 1 000 блоков — \(showMs.map(ProbeEditor.format).joined(separator: ", ")) мс (предел 500)",
            "Версии: восстановление 1 000 блоков — \(ProbeEditor.format(restoreMs)) мс (предел 1 000)",
            "Версии: набор при записи версий — p95 \(ProbeEditor.format(ProbeEditor.p95(typing))) мс, худший \(ProbeEditor.format(typing.max() ?? 0)) мс, версий за набор \(recorded.value)",
        ].joined(separator: "\n")
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertLessThanOrEqual(showMs.max() ?? .infinity, Self.showBudgetMs)
        XCTAssertLessThanOrEqual(restoreMs, Self.restoreBudgetMs)
        XCTAssertLessThanOrEqual(ProbeEditor.p95(typing), Self.typingBudgetMs)
        XCTAssertGreaterThan(recorded.value, 0, "Версии во время набора не писались")
    }
}

final class RecordedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
