import AppKit
import DatabaseGrid
import Databases
import NotesCore
import XCTest

/// Общее для проб баз этапа 0 (research R20): эталон баз (quickstart.md), окно с сеткой, снимок и «нарисовано ли».
enum DatabaseProbeLibrary {
    /// Эталон баз на пустой базе: создаётся один раз во временной папке, каждой пробе — своя копия.
    static func copy() throws -> (folder: URL, store: NotesStore, sample: DatabaseSampleGenerator.Sample) {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotion-db004-sample-v3", isDirectory: true)
            .appendingPathComponent("MyNotion.sqlite")
        if !FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            let started = Date()
            // Генерация копит в пуле автоосвобождения много мусора: без своего пула его освобождает главный поток уже во
            // время замера пробы — остановка 0,7–0,9 с, не относящаяся к тому, что меряется (US5, T056).
            try autoreleasepool { try DatabaseSampleGenerator().generate(at: source) }
            print("Эталон баз: создан за \(String(format: "%.1f", Date().timeIntervalSince(started))) с")
        }
        try ReferenceLibrary.migrate(source)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotion-db-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("MyNotion.sqlite")
        try FileManager.default.copyItem(at: source, to: url)
        let store = try NotesStore(database: AppDatabase.open(at: url), clock: HybridLogicalClock(deviceId: UUID()))
        return (folder, store, try XCTUnwrap(try DatabaseSampleGenerator.existing(in: store)))
    }
}

/// Окно пробы 1440×900 с видом во всё окно.
@MainActor
final class DatabaseProbeWindow {
    let window: NSWindow

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.makeKeyAndOrderFront(nil)
    }

    func show(_ view: NSView) {
        window.contentView?.subviews.forEach { $0.removeFromSuperview() }
        view.frame = window.contentView!.bounds
        view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(view)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Нарисовать окно сейчас — как кадр: раскладка, рисование, передача слоёв.
    func render() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    func pump(_ milliseconds: Int) {
        autoreleasepool {
            RunLoop.current.run(until: Date().addingTimeInterval(Double(milliseconds) / 1_000))
            window.displayIfNeeded()
        }
    }

    func close() { window.orderOut(nil) }
}

@MainActor
enum DatabaseProbeShots {
    static func snapshot(_ view: NSView) -> NSBitmapImageRep? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// Доля пикселей рамки `rect` (координаты перевёрнутого вида `view`), заметно отличных от фона.
    static func ink(in bitmap: NSBitmapImageRep, rect: NSRect, of view: NSView) -> Double {
        let bounds = view.bounds
        let clipped = rect.intersection(bounds)
        guard !clipped.isEmpty else { return 0 }
        let scale = CGFloat(bitmap.pixelsWide) / bounds.width
        let top = view.isFlipped ? clipped.minY : bounds.height - clipped.maxY
        let background = bitmap.colorAt(x: Int((clipped.maxX - 3) * scale), y: Int((top + 2) * scale))?.usingColorSpace(.deviceRGB)
        var inked = 0, total = 0
        for y in stride(from: Int((top + 2) * scale), to: Int((top + clipped.height - 2) * scale), by: 2) {
            for x in stride(from: Int((clipped.minX + 2) * scale), to: Int((clipped.maxX - 2) * scale), by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += 1
                let delta = abs(color.redComponent - (background?.redComponent ?? 1)) + abs(color.greenComponent - (background?.greenComponent ?? 1))
                    + abs(color.blueComponent - (background?.blueComponent ?? 1))
                if delta > 0.08 { inked += 1 }
            }
        }
        return total == 0 ? 0 : Double(inked) / Double(total)
    }

    /// `~/probe-shots/<name>.png` (в виртуальном Mac — домашняя папка пользователя тестов) и вложение отчёта.
    @discardableResult
    static func save(_ bitmap: NSBitmapImageRep, name: String, to test: XCTestCase) -> String {
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
}

/// Сетка вида из хранилища — как её откроет приложение: схема, запрос вида, окно видимых строк.
@MainActor
enum DatabaseProbeGrid {
    static func open(viewId: UUID, store: NotesStore, loadLimit: Int? = nil, scrolls: Bool = true, search: String? = nil) throws -> DatabaseGridView {
        let opened = try XCTUnwrap(try ViewQuery.open(viewId, in: store, search: search))
        let content = GridContent(store: store, catalog: opened.catalog, columns: columns(of: opened.view, catalog: opened.catalog),
                                  rowIds: opened.result.rowIds, loadLimit: loadLimit)
        return DatabaseGridView(content: content, scrollsVertically: scrolls)
    }

    /// Видимые колонки вида по порядку.
    static func columns(of view: DatabaseView, catalog: DatabaseCatalog) -> [GridColumn] {
        (view.columns.array ?? []).compactMap { column -> GridColumn? in
            guard column["isVisible"]?.bool != false, let id = column["propertyId"]?.string.flatMap(UUID.init(uuidString:)),
                  let property = catalog.propertiesById[id] else { return nil }
            return GridColumn(property: property, width: CGFloat(column["width"]?.number ?? 200))
        }
    }
}
