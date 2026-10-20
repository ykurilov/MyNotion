import AppKit
import NotesCore
import PageEditor
import XCTest

/// «Богатая» страница 002 (1 000 блоков, виды таблиц, кода, картинок) в настоящем `PageTextView` в видимом окне —
/// для проб этапа 0 003 (research R14). Снимки окна — тем же `cacheDisplay`, что `--window-snapshot` приложения.
@MainActor
final class RichProbePage {
    let folder: URL
    let store: NotesStore
    let pageId: UUID
    let window: NSWindow
    let scrollView: NSScrollView
    private(set) var textView: PageTextView

    init(windowSize: NSSize = NSSize(width: 1200, height: 800)) throws {
        _ = NSApplication.shared
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotion-probe-\(UUID().uuidString)", isDirectory: true)
        store = try NotesStore(database: AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")),
                               clock: HybridLogicalClock(deviceId: UUID()))
        pageId = try RichPageGenerator(parts: BlockKinds.richPageParts).ensure(in: store)
        ProbeMediaServices.installOnce(in: folder)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: windowSize), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        scrollView = NSScrollView(frame: window.contentLayoutRect)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        window.contentView = scrollView
        textView = try Self.editor(for: pageId, in: store)
        show(textView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
    }

    /// Новый редактор страницы, как при открытии страницы в окне.
    static func editor(for pageId: UUID, in store: NotesStore) throws -> PageTextView {
        let document = PageDocument(content: try XCTUnwrap(try store.pageContent(pageId)))
        return PageTextView(document: document, initialFocus: .unchanged)
    }

    /// Поставить редактор в окно вместо прежнего (прежний уходит из окна и освобождается).
    func show(_ editor: PageTextView) {
        textView = editor
        scrollView.documentView = editor
        editor.frame.size.width = scrollView.contentSize.width
        window.makeFirstResponder(editor)
    }

    func settle(_ milliseconds: Int = 300) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
        window.displayIfNeeded()
    }

    /// Ходы цикла событий в своём пуле автоосвобождения, как в окне приложения. Асинхронное ожидание в тесте XCTest
    /// пул не освобождает, и всё автоосвобождённое (старые тексты, виды) копится до конца теста.
    func pump(_ milliseconds: Int) {
        autoreleasepool {
            RunLoop.current.run(until: Date().addingTimeInterval(Double(milliseconds) / 1_000))
            window.displayIfNeeded()
        }
    }

    /// Занято в куче процесса, МБ (`heap`): объекты, а не пустые страницы, которые система ещё не забрала.
    static func heapAllocatedMB() -> Double {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/heap")
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return 0 }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        // «All zones: 108207 nodes (80228352 bytes)»
        guard let line = text.split(separator: "\n").first(where: { $0.contains("All zones:") && $0.contains("bytes)") }),
              let open = line.firstIndex(of: "("), let bytes = Double(line[line.index(after: open)...].prefix { $0.isNumber }) else { return 0 }
        return bytes / 1_048_576
    }

    func close() {
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Блоки и прокрутка

    func blockIndex(of kind: BlockKind) -> Int? {
        textView.document.blocks.firstIndex { $0.kind == kind }
    }

    /// Начало абзаца блока `index` потока страницы.
    func location(ofBlock index: Int) -> Int {
        let string = textView.string as NSString
        var location = 0
        for _ in 0..<index { location = NSMaxRange(string.paragraphRange(for: NSRange(location: location, length: 0))) }
        return location
    }

    /// Прокрутить так, чтобы абзац блока стоял у верха окна.
    func scroll(toBlock index: Int) {
        let location = location(ofBlock: index)
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        let rect = textView.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        let point = textView.convert(window.convertFromScreen(rect).origin, from: nil)
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, point.y - 80)))
        scrollView.reflectScrolledClipView(clip)
        textView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// Место прокрутки, как его хранит вкладка (data-model.md, «Tab.scroll»): блок у верха и сдвиг от верха его абзаца.
    func scrollAnchor() -> (block: Int, offset: CGFloat) {
        let block = topVisibleBlockIndex() ?? 0
        return (block, textView.visibleRect.minY - (blockTopLaidOut(block) ?? textView.visibleRect.minY))
    }

    /// Вернуть место прокрутки так, как его вернёт вкладка: TextKit 2 ставит видимую область на абзац блока
    /// (`relocateViewport`) — раскладывается только он и соседи, а не всё выше; затем сдвиг.
    func restore(_ anchor: (block: Int, offset: CGFloat)) {
        guard let layoutManager = textView.textLayoutManager, let storage = textView.textContentStorage,
              let location = storage.location(storage.documentRange.location, offsetBy: location(ofBlock: anchor.block)) else { return }
        let y = layoutManager.textViewportLayoutController.relocateViewport(to: location)
        textView.layoutSubtreeIfNeeded()
        let top = blockTopLaidOut(anchor.block) ?? (y + textView.textContainerOrigin.y)
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, top + anchor.offset)))
        scrollView.reflectScrolledClipView(clip)
        window.displayIfNeeded()
    }

    /// Верх абзаца блока в координатах текста по разложенному фрагменту; `nil` — абзац не разложен.
    func blockTopLaidOut(_ index: Int) -> CGFloat? {
        guard let layoutManager = textView.textLayoutManager, let storage = textView.textContentStorage,
              let location = storage.location(storage.documentRange.location, offsetBy: location(ofBlock: index)),
              let fragment = layoutManager.textLayoutFragment(for: location) else { return nil }
        return fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y
    }

    /// Где окажется верх видимой области после возврата места `anchor`: запоминается при уходе со вкладки.
    private(set) var leftTops: [Int: CGFloat] = [:]
    func blockTopAfterRestore(of anchor: (block: Int, offset: CGFloat)) -> CGFloat? {
        leftTops[anchor.block * 10_000 + Int(anchor.offset.rounded())]
    }

    func rememberTop(for anchor: (block: Int, offset: CGFloat)) {
        leftTops[anchor.block * 10_000 + Int(anchor.offset.rounded())] = textView.visibleRect.minY
    }

    /// Верх абзаца блока в координатах текста.
    func blockTop(_ index: Int) -> CGFloat {
        let location = location(ofBlock: index)
        let rect = textView.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        let point = textView.convert(window.convertFromScreen(rect), from: nil)
        return min(point.minY, point.maxY)
    }

    /// Блок, чей абзац сейчас у верха видимой области.
    func topVisibleBlockIndex() -> Int? {
        let visible = textView.visibleRect
        let point = NSPoint(x: textView.textContainerOrigin.x + 40, y: visible.minY + 60)
        let location = textView.characterIndexForInsertion(at: point)
        let string = textView.string as NSString
        var index = 0
        var start = 0
        while start < min(location, string.length) {
            let next = NSMaxRange(string.paragraphRange(for: NSRange(location: start, length: 0)))
            if next > location { break }
            start = next
            index += 1
        }
        return index
    }

    // MARK: Снимки

    /// Вид внутри текста по имени класса (`TableView`, `CodeBlockView`, `ImageBlockView`), видимый на экране.
    func visibleSubview(named className: String) -> NSView? {
        func find(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)) == className, !view.isHiddenOrHasHiddenAncestor,
               view.convert(view.bounds, to: textView).intersects(textView.visibleRect) { return view }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return find(textView)
    }

    /// Снимок окна целиком.
    func snapshot() -> NSBitmapImageRep? {
        guard let frameView = window.contentView?.superview,
              let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        return bitmap
    }

    /// Доля пикселей снимка в рамке вида, заметно отличных от фона страницы: вид реально нарисован.
    func inkFraction(of view: NSView, in bitmap: NSBitmapImageRep) -> Double {
        guard let frameView = window.contentView?.superview else { return 0 }
        let rect = view.convert(view.bounds, to: frameView).intersection(frameView.bounds)
        return Self.inkFraction(in: bitmap, rect: rect, frameView: frameView)
    }

    static func inkFraction(in bitmap: NSBitmapImageRep, rect: NSRect, frameView: NSView) -> Double {
        guard !rect.isEmpty else { return 0 }
        let scale = CGFloat(bitmap.pixelsWide) / frameView.bounds.width
        let background = bitmap.colorAt(x: 2, y: Int(CGFloat(bitmap.pixelsHigh) / 2))?.usingColorSpace(.deviceRGB)
        // Снимок `cacheDisplay` идёт сверху вниз; рамка вида — в координатах рамки окна (снизу вверх, если не перевёрнута).
        let top = frameView.isFlipped ? rect.minY : frameView.bounds.height - rect.maxY
        var inked = 0, total = 0
        let step = 2
        for y in stride(from: Int(top * scale), to: Int((top + rect.height) * scale), by: step) {
            for x in stride(from: Int(rect.minX * scale), to: Int(rect.maxX * scale), by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += 1
                let delta = abs(color.redComponent - (background?.redComponent ?? 1)) + abs(color.greenComponent - (background?.greenComponent ?? 1))
                    + abs(color.blueComponent - (background?.blueComponent ?? 1))
                if delta > 0.08 { inked += 1 }
            }
        }
        return total == 0 ? 0 : Double(inked) / Double(total)
    }

    /// Записать снимок в `~/probe-shots/<name>.png` (в виртуальном Mac — домашняя папка пользователя тестов)
    /// и приложить к отчёту теста. Возвращает путь.
    @discardableResult
    func save(_ bitmap: NSBitmapImageRep, name: String, to test: XCTestCase) -> String {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("probe-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).png")
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: url, options: .atomic)
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            test.add(attachment)
        }
        return url.path
    }

    /// Память процесса (физический след), МБ; освобождённое, но ещё не отданное системе — отдаётся перед замером,
    /// как это делает система при нехватке памяти.
    static func footprintMB() -> Double {
        malloc_zone_pressure_relief(nil, 0)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

/// Службы медиа-блоков пробы: каждая картинка «на месте» — один файл-образец 1600 × 900 с градиентом и полосами,
/// как настоящая картинка (в приложении службы ставит `AppMediaServices`).
@MainActor
final class ProbeMediaServices: MediaBlockServices {
    private static var installed: ProbeMediaServices?
    let sampleURL: URL

    init(sampleURL: URL) {
        self.sampleURL = sampleURL
    }

    static func installOnce(in folder: URL) {
        guard installed == nil else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotion-probe-sample.png")
        if !FileManager.default.fileExists(atPath: url.path) {
            let image = NSImage(size: NSSize(width: 1600, height: 900), flipped: false) { rect in
                NSGradient(starting: .systemOrange, ending: .systemPurple)?.draw(in: rect, angle: 30)
                NSColor.white.withAlphaComponent(0.5).setFill()
                for x in stride(from: 0, to: rect.width, by: 200) { NSRect(x: x, y: 0, width: 60, height: rect.height).fill() }
                return true
            }
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
        }
        let services = ProbeMediaServices(sampleURL: url)
        installed = services
        MediaBlocks.install(services)
    }

    func availability(of ref: AttachmentRef) -> MediaAvailability { .ready(sampleURL) }
    func reserveFileImport(at url: URL) throws -> AttachmentRef { throw CocoaError(.featureUnsupported) }
    func importFile(at url: URL, into reserved: AttachmentRef, progress: @escaping @Sendable (Double) -> Void) async throws -> AttachmentRef {
        throw CocoaError(.featureUnsupported)
    }
    func importData(_ data: Data, name: String, contentType: String) async throws -> AttachmentRef { throw CocoaError(.featureUnsupported) }
    func downloadFile(from url: URL) async throws -> AttachmentRef { throw CocoaError(.featureUnsupported) }
    func videoSource(for url: URL) -> VideoSource? { nil }
    func linkPreview(for url: URL) async -> MediaLinkPreview { MediaLinkPreview(title: nil, description: nil, image: nil, icon: nil) }
    func videoCover(for url: URL) async -> MediaLinkPreview? { nil }
    func posterImage(forVideoAt url: URL) async -> NSImage? { nil }
    func makePlayer(for block: Block, fileURL: URL?) -> NSView? { nil }
    func open(_ url: URL) {}
}
