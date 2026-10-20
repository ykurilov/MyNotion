import AppKit
import Compression
import NotesCore
import PageEditor
import XCTest

/// Проба просмотра версии (T005, research R14, п. 3): второй редактор «только чтение» на документе из снимка
/// 1 000 блоков (JSON, сжатый LZFSE, как `page_version.snapshot`) поверх окна. Показ ≤ 500 мс; снимок не пустой, виды 002
/// нарисованы; нажатия клавиш документ не меняют; после закрытия память — исходная ± 5 МБ.
@MainActor
final class VersionPreviewProbeTests: XCTestCase {
    static let showBudgetMs = 500.0
    static let memoryToleranceMB = 5.0

    /// Блок снимка: все поля записи блока (data-model.md, «PageSnapshot»).
    struct SnapshotBlock: Codable {
        let id: UUID, kind: BlockKind, text: InlineText, indent: Int, isChecked: Bool, linkedPageId: UUID?
        let sortKey: FractionalSortKey, containerId: UUID?, color: BlockColor, props: BlockProps
    }

    func testReadOnlyPreviewShowsQuicklyAndReleasesMemory() async throws {
        let page = try RichProbePage()
        defer { page.close() }
        try await page.settle()
        let content = try XCTUnwrap(try page.store.pageContent(page.pageId))
        let snapshot = try Self.compress(JSONEncoder().encode(content.blocks.map {
            SnapshotBlock(id: $0.id, kind: $0.kind, text: $0.text, indent: $0.indent, isChecked: $0.isChecked, linkedPageId: $0.linkedPageId,
                          sortKey: $0.sortKey, containerId: $0.containerId, color: $0.color, props: $0.props)
        }))

        var showMs: [Double] = []
        var memory: [(before: Double, open: Double, after: Double)] = []
        var lines: [String] = []
        var shots: [String] = []
        for round in 1...3 {
            for _ in 0..<3 { try await page.settle(100) }
            let before = RichProbePage.footprintMB()
            var preview: (scroll: NSScrollView, editor: PageTextView)?
            let ms = try ProbeEditor.measure {
                preview = try Self.showPreview(snapshot: snapshot, page: content.page, over: page)
            }
            showMs.append(ms)
            let (scroll, editor) = try XCTUnwrap(preview)
            try await page.settle()
            let open = RichProbePage.footprintMB()

            // Ввод: буквы, Enter, ⌫ — документ и текст не меняются.
            let blocksBefore = editor.document.blocks
            let textBefore = editor.string
            editor.setSelectedRange(NSRange(location: 10, length: 0))
            for characters in ["а", "b", "\r", "\u{7f}"] {
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: page.window.windowNumber,
                                                   context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                                                   keyCode: characters == "\r" ? 36 : characters == "\u{7f}" ? 51 : 0) else { continue }
                editor.keyDown(with: event)
            }
            editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(editor.document.blocks, blocksBefore, "Нажатия изменили документ версии")
            XCTAssertEqual(editor.string, textBefore, "Нажатия изменили текст версии")

            if round == 1 {
                // Снимки: верх и виды 002.
                editor.scroll(.zero)
                page.window.displayIfNeeded()
                if let bitmap = page.snapshot() {
                    let ink = RichProbePage.inkFraction(in: bitmap, rect: scroll.convert(scroll.bounds, to: page.window.contentView?.superview),
                                                        frameView: page.window.contentView!.superview!)
                    XCTAssertGreaterThan(ink, 0.02, "Просмотр версии пустой")
                    shots.append(page.save(bitmap, name: "version-верх", to: self))
                    lines.append("Проба версии: верх нарисован \(String(format: "%.0f", ink * 100)) %")
                }
                let previewPage = PreviewProbe(page: page, editor: editor, scroll: scroll)
                for (kind, className) in [(BlockKind.table, "TableView"), (.code, "CodeBlockView"), (.image, "ImageBlockView")] {
                    let index = try XCTUnwrap(editor.document.blocks.firstIndex { $0.kind == kind })
                    previewPage.scroll(toBlock: index)
                    try await page.settle(150)
                    let view = previewPage.visibleSubview(named: className)
                    XCTAssertNotNil(view, "В просмотре нет вида \(className)")
                    guard let view, let bitmap = page.snapshot() else { continue }
                    let ink = page.inkFraction(of: view, in: bitmap)
                    XCTAssertGreaterThan(ink, PageLayoutProbeTests.minimumInk, "В просмотре вид \(className) пустой")
                    shots.append(page.save(bitmap, name: "version-\(className)", to: self))
                    lines.append("Проба версии: \(className) нарисован \(String(format: "%.0f", ink * 100)) %")
                }
            }

            scroll.removeFromSuperview()
            preview = nil
            // Нажатия сделали редактор просмотра клиентом системы ввода; закрытый просмотр отдаёт её странице, как в окне.
            page.window.makeFirstResponder(page.textView)
            page.textView.inputContext?.activate()
            for _ in 0..<5 { try await page.settle(100) }
            memory.append((before, open, RichProbePage.footprintMB()))
        }
        let liveAfterClose = PageTextView.livePageEditorCount

        let summary = ([
            "Проба версии: показ «только чтение» 1 000 блоков из снимка \(snapshot.count / 1024) КБ — \(showMs.map(ProbeEditor.format).joined(separator: ", ")) мс (предел 500)",
            "Проба версии: память до / открыт / после закрытия — " + memory.map { "\(ProbeEditor.format($0.before)) / \(ProbeEditor.format($0.open)) / \(ProbeEditor.format($0.after))" }.joined(separator: "; ") + " МБ",
            "Проба версии: живых редакторов страницы после закрытия \(liveAfterClose)",
        ] + lines + ["Снимок: \(shots.joined(separator: ", "))"]).joined(separator: "\n")
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertLessThanOrEqual(showMs.max() ?? .infinity, Self.showBudgetMs, "Показ версии дольше 500 мс")
        // После каждого закрытия память не выше исходной больше чем на 5 МБ; от круга к кругу не растёт.
        for (round, sample) in memory.enumerated() {
            XCTAssertLessThanOrEqual(sample.after - sample.before, Self.memoryToleranceMB, "Круг \(round + 1): память после закрытия не вернулась")
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(memory.last).after - memory[0].after, Self.memoryToleranceMB, "Память растёт от круга к кругу")
        // Последний редактор просмотра система может держать ещё немного (проверка орфографии, ввод): копиться ему
        // нельзя — память от круга к кругу не растёт (проверка выше); число — справочно.
        XCTAssertLessThanOrEqual(liveAfterClose, 2, "Редакторы просмотра копятся")
    }

    /// Распаковать снимок, собрать документ (не сохраняется) и редактор «только чтение» поверх страницы.
    static func showPreview(snapshot: Data, page: Page, over probe: RichProbePage) throws -> (NSScrollView, PageTextView) {
        let blocks = try JSONDecoder().decode([SnapshotBlock].self, from: decompress(snapshot)).map {
            Block(id: $0.id, pageId: page.id, kind: $0.kind, text: $0.text, indent: $0.indent, isChecked: $0.isChecked, linkedPageId: $0.linkedPageId,
                  sortKey: $0.sortKey, containerId: $0.containerId, color: $0.color, props: $0.props)
        }
        let document = PageDocument(content: PageContent(page: page, blocks: blocks, removedContainers: [:]))
        let editor = PageTextView(document: document, initialFocus: .unchanged)
        editor.isEditable = false
        let host = try XCTUnwrap(probe.window.contentView?.superview)
        let scroll = NSScrollView(frame: probe.window.contentView!.frame)
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        editor.frame.size.width = scroll.contentSize.width
        host.addSubview(scroll, positioned: .above, relativeTo: probe.window.contentView)
        probe.window.displayIfNeeded()
        return (scroll, editor)
    }

    static func compress(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .lzfse) as Data
    }

    static func decompress(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .lzfse) as Data
    }
}

/// Прокрутка и поиск видов в редакторе просмотра (своя прокрутка поверх окна пробы).
@MainActor
struct PreviewProbe {
    let page: RichProbePage
    let editor: PageTextView
    let scroll: NSScrollView

    func scroll(toBlock index: Int) {
        let string = editor.string as NSString
        var location = 0
        for _ in 0..<index { location = NSMaxRange(string.paragraphRange(for: NSRange(location: location, length: 0))) }
        editor.scrollRangeToVisible(NSRange(location: location, length: 0))
        let rect = editor.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        let point = editor.convert(page.window.convertFromScreen(rect).origin, from: nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, point.y - 80)))
        scroll.reflectScrolledClipView(scroll.contentView)
        editor.layoutSubtreeIfNeeded()
        page.window.displayIfNeeded()
    }

    func visibleSubview(named className: String) -> NSView? {
        func find(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)) == className, !view.isHiddenOrHasHiddenAncestor,
               view.convert(view.bounds, to: editor).intersects(editor.visibleRect) { return view }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return find(editor)
    }
}
