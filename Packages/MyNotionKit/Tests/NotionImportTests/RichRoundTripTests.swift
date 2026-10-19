import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import MarkdownExport
import NotesCore
import PageEditor
import Synchronization
import Testing
@testable import NotionImport

/// Круговая проверка SC-105 на эталонной «богатой» странице (quickstart.md): все блоки 002 → выгрузка в Markdown →
/// импорт → тот же текст, блоки, оформление в строке и в блоке, свойства и файлы (сверка SHA-256).
/// Свёрнутость и сделанность напоминаний в выгрузку не попадают (contracts/markdown-and-notion.md) и не сравниваются.
@Suite("Круг «богатой» страницы: выгрузка → импорт")
struct RichRoundTripTests {
    @Test("«Богатая» страница и строка со всеми оформлениями возвращаются без потерь")
    func richPageRoundTrip() throws {
        let fixture = try RoundTripFixture()
        let richId = try RichPageGenerator(parts: BlockKinds.richPageParts).ensure(in: fixture.source)
        let inlineId = try fixture.source.write { transaction in
            let page = Page(title: "Оформление в строке", icon: "🎨", sortKey: .between(try transaction.allPages().map(\.sortKey).max(), nil),
                            createdAt: Date(), updatedAt: Date())
            try transaction.insertPage(page)
            var key: FractionalSortKey?
            for text in Self.inlineSamples(mentioning: richId) {
                key = .between(key, nil)
                try transaction.insertBlock(Block(pageId: page.id, kind: .paragraph, text: text, sortKey: key!))
            }
            return page.id
        }
        let exported = try fixture.export()
        #expect(exported.missingFileCount == 0)
        let sourceRich = try fixture.snapshot(of: richId, in: fixture.source)
        let sourceInline = try fixture.snapshot(of: inlineId, in: fixture.source)
        #expect(sourceRich.count >= RichPageGenerator.blockCount)
        let report = try fixture.runImport(from: exported.folder)

        let importedRich = try #require(try fixture.target.pageOutline().first { $0.title == RichPageGenerator.title })
        let importedInline = try #require(try fixture.target.pageOutline().first { $0.title == "Оформление в строке" })
        #expect(importedRich.icon == "🧪")
        #expect(importedInline.icon == "🎨")
        let targetRich = try fixture.snapshot(of: importedRich.id, in: fixture.target)
        let targetInline = try fixture.snapshot(of: importedInline.id, in: fixture.target)

        // Текст — 100 %: все знаки всех блоков по порядку.
        #expect(targetRich.map(\.text).joined(separator: "\n") == sourceRich.map(\.text).joined(separator: "\n"))
        #expect(targetInline.map(\.text) == sourceInline.map(\.text))
        // Блоки, оформление и свойства — по одному, чтобы расхождение было видно сразу.
        #expect(targetRich.count == sourceRich.count)
        for (index, (target, source)) in zip(targetRich, sourceRich).enumerated() where target != source {
            Issue.record("Блок \(index + 1) «богатой» страницы:\n было  \(source)\n стало \(target)")
        }
        for (index, (target, source)) in zip(targetInline, sourceInline).enumerated() where target != source {
            Issue.record("Абзац \(index + 1) «Оформления в строке»:\n было  \(source)\n стало \(target)")
        }
        // Файлы: импортированы те же байты, что выгружены, и ни одного лишнего (общий файл двух блоков копируется каждому).
        #expect(fixture.importer.hashes == fixture.sourceFileHashes)
        // Своя выгрузка не упрощается (строка про цвета и колонки Notion — общая для любого импорта, T115).
        #expect(report.simplified.flatMap(\.items).isEmpty)
    }

    /// Абзацы со всеми оформлениями в строке: начертания, ссылка, цвета текста и фона, упоминание, дата с напоминанием
    /// и без, формула в строке.
    static func inlineSamples(mentioning pageId: UUID) -> [InlineText] {
        func text(_ parts: [(String, InlineStyle?)]) -> InlineText {
            var string = ""
            var runs: [StyledRun] = []
            for (fragment, style) in parts {
                let length = (fragment as NSString).length
                if let style { runs.append(StyledRun(start: (string as NSString).length, length: length, style: style)) }
                string += fragment
            }
            return InlineText(string, runs: runs).normalized()
        }
        let atom = "\u{FFFC}"
        let reminder = DateMention.Reminder(fireAt: try! Date("2026-10-20T00:00:00Z", strategy: .iso8601))
        return [
            text([("Обычный, ", nil), ("жирный", .bold), (", ", nil), ("курсив", .italic), (", ", nil), ("зачёркнутый", .strikethrough),
                  (", ", nil), ("подчёркнутый", .underline), (", ", nil), ("код", .code), (" и ", nil),
                  ("ссылка", .link(URL(string: "https://example.com/a?b=1")!)), (".", nil)]),
            text([("Красный текст", .textColor(.red)), (" и ", nil), ("жёлтый фон", .backgroundColor(.yellow)), (".", nil)]),
            text([("Смотри ", nil), (atom, .mention(pageId)), (" сегодня.", nil)]),
            text([("Встреча ", nil), (atom, .date(DateMention(start: "2026-10-20T09:00", includesTime: true, timeZone: "Asia/Makassar",
                                                             reminder: reminder))),
                  (" и срок ", nil), (atom, .date(DateMention(start: "2026-10-21", includesTime: false, timeZone: "Asia/Makassar"))),
                  (".", nil)]),
            text([("Формула ", nil), (atom, .equation("E = mc^2")), (" в строке, цена $5 и $10.", nil)]),
        ]
    }
}

/// Блок для сравнения: всё, что переносит выгрузка, без id, ключей порядка и мест хранения.
private struct BlockSnapshot: Equatable, CustomStringConvertible {
    var depth: Int
    var kind: BlockKind
    var text: String
    /// Оформление в строке; упоминание — названием страницы, дата — без своего id.
    var runs: [String]
    var indent: Int
    var isChecked: Bool
    var color: BlockColor
    /// Свойства без файлов; столбец ячейки — номером столбца таблицы.
    var props: BlockProps
    /// Файлы блока: поле, имя и SHA-256 байтов.
    var files: [String]
    var linkedPageTitle: String?

    var description: String {
        "\(String(repeating: "  ", count: depth))\(kind.rawValue) «\(text)» runs=\(runs) indent=\(indent) checked=\(isChecked) "
            + "color=\(color) props=\(props.values) files=\(files) link=\(linkedPageTitle ?? "—")"
    }
}

/// Исходная база с файлами вложений, выгрузка во временную папку и импорт в чистую базу.
private final class RoundTripFixture {
    let folder: URL
    let source: NotesStore
    let target: NotesStore
    let importer = HashingAttachmentImporter()
    /// Файлы вложений исходной базы: id ссылки → файл на диске.
    private var files: [UUID: URL] = [:]
    /// SHA-256 настоящих байтов файла по id ссылки исходной базы.
    private var sourceHashes: [UUID: String] = [:]
    var sourceFileHashes: Set<String> { Set(sourceHashes.values) }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotionRichRoundTrip-\(UUID().uuidString)")
        source = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("source/MyNotion.sqlite")),
                            clock: HybridLogicalClock(deviceId: UUID()))
        target = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("target/MyNotion.sqlite")),
                            clock: HybridLogicalClock(deviceId: UUID()))
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// Выгрузить исходную базу; у каждого вложения — свой файл со своими байтами, у картинок — настоящий PNG.
    func export() throws -> MarkdownExportResult {
        let originals = folder.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        for page in try source.pageOutline() {
            for block in try source.pageContent(page.id)?.blocks ?? [] {
                for ref in block.props.attachmentRefs where files[ref.id] == nil {
                    let size = block.props.pixelSize ?? PixelSize(width: 160, height: 90)
                    let data = block.kind == .image ? try Self.png(width: size.width, height: size.height)
                        : Data("Файл «\(ref.name)», \(ref.id.uuidString)\n".utf8)
                    let url = originals.appendingPathComponent(ref.id.uuidString)
                    try data.write(to: url)
                    files[ref.id] = url
                    sourceHashes[ref.id] = Self.sha(data)
                }
            }
        }
        let exportFolder = folder.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        let copies = files
        return try MarkdownExporter(store: source, attachmentFile: { copies[$0] }).export(into: exportFolder)
    }

    func runImport(from exportFolder: URL) throws -> NotionImportReport {
        let prepared = try NotionExportUnpacker().prepare(exportFolder)
        defer { prepared.discard() }
        return try NotionImporter(store: target, attachments: importer).importExport(prepared)
    }

    /// Блоки страницы деревом: поток страницы по порядку, у контейнера — его блоки сразу после него.
    func snapshot(of pageId: UUID, in store: NotesStore) throws -> [BlockSnapshot] {
        let blocks = try #require(try store.pageContent(pageId)).blocks
        let titles = Dictionary(try store.pageOutline().map { ($0.id, $0.title) }) { first, _ in first }
        let byContainer = Dictionary(grouping: blocks, by: \.containerId)
        let isSource = store === source
        var result: [BlockSnapshot] = []
        func visit(_ containerId: UUID?, depth: Int) {
            let siblings = (byContainer[containerId] ?? []).sorted { $0.sortKey < $1.sortKey }
            // Глубина — как на экране: записанная глубина больше допустимой при показе урезается, и выгрузка пишет показанную.
            let indents = BlockNesting.displayIndents(siblings)
            for (block, indent) in zip(siblings, indents) {
                var props = block.props
                var files: [String] = []
                for (field, ref) in [("attachment", props.attachment), ("poster", props.poster), ("image", props.image),
                                     ("icon", props.iconAttachment)] {
                    guard let ref else { continue }
                    let hash = isSource ? sourceHashes[ref.id] : importer.hash(of: ref.id)
                    files.append("\(field): \(ref.name) \(hash ?? "нет байтов")")
                }
                props.attachment = nil
                props.poster = nil
                props.image = nil
                if props.iconAttachment != nil { props.iconAttachment = nil }
                // Ячейка ссылается на столбец своей таблицы по id, а id столбцов при импорте новые: сравнивается номер столбца.
                if let columnId = props.columnId {
                    let parentColumns = (byContainer[containerId.flatMap { id in blocks.first { $0.id == id }?.containerId }] ?? [])
                        .filter { $0.kind == .tableColumn }.sorted { $0.sortKey < $1.sortKey }
                    props.columnId = nil
                    props.values["column"] = .number(Double(parentColumns.firstIndex { $0.id == columnId } ?? -1))
                }
                let runs = block.text.runs.map { run -> String in
                    let place = "\(run.start)+\(run.length)"
                    switch run.style {
                    case .mention(let id):
                        return "\(place) упоминание «\(titles[id] ?? "?")»"
                    case .date(let date):
                        return "\(place) дата \(date.start) время=\(date.includesTime) \(date.timeZone) напомнить=\(date.reminder.map { "\($0.fireAt)" } ?? "—")"
                    default:
                        return "\(place) \(run.style)"
                    }
                }
                result.append(BlockSnapshot(depth: depth, kind: block.kind, text: block.text.string, runs: runs, indent: indent,
                                            isChecked: block.isChecked, color: block.color, props: props, files: files.sorted(),
                                            linkedPageTitle: block.linkedPageId.map { titles[$0] ?? "?" }))
                visit(block.id, depth: depth + 1)
            }
        }
        visit(nil, depth: 0)
        return result
    }

    /// PNG одного цвета нужного размера: импорт берёт размер картинки из файла.
    static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Хранилище вложений импорта: запоминает SHA-256 скопированных байтов.
private final class HashingAttachmentImporter: NotionAttachmentImporting, Sendable {
    private let copies = Mutex<[UUID: String]>([:])

    func importFile(at url: URL) throws -> AttachmentRef {
        let data = try Data(contentsOf: url)
        let sha = RoundTripFixture.sha(data)
        let ref = AttachmentRef(name: url.lastPathComponent, byteCount: data.count, contentType: "public.data", sha256: sha)
        copies.withLock { $0[ref.id] = sha }
        return ref
    }

    func hash(of id: UUID) -> String? { copies.withLock { $0[id] } }
    var hashes: Set<String> { Set(copies.withLock { $0.values }) }
}
