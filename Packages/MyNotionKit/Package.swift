// swift-tools-version: 6.2
import PackageDescription

/// Модули MyNotion. Ядро `NotesCore` ни от кого из добавок не зависит (конституция, принцип V).
let package = Package(
    name: "MyNotionKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VisualStyle", targets: ["VisualStyle"]),
        .library(name: "NotesCore", targets: ["NotesCore"]),
        .library(name: "PageTree", targets: ["PageTree"]),
        .library(name: "PageEditor", targets: ["PageEditor"]),
        .library(name: "EmojiPicker", targets: ["EmojiPicker"]),
        .library(name: "PageSearch", targets: ["PageSearch"]),
        .library(name: "MarkdownExport", targets: ["MarkdownExport"]),
        .library(name: "NotionImport", targets: ["NotionImport"]),
        .library(name: "Sync", targets: ["Sync"]),
        .library(name: "UIGallery", targets: ["UIGallery"]),
        .library(name: "ServiceLaunch", targets: ["ServiceLaunch"]),
        .library(name: "CodeHighlighting", targets: ["CodeHighlighting"]),
        .library(name: "MathRendering", targets: ["MathRendering"]),
        .library(name: "Attachments", targets: ["Attachments"]),
        .library(name: "LinkPreview", targets: ["LinkPreview"]),
        .library(name: "Reminders", targets: ["Reminders"]),
        .library(name: "EmbeddedMedia", targets: ["EmbeddedMedia"]),
        .library(name: "Backlinks", targets: ["Backlinks"]),
        .library(name: "PageVersions", targets: ["PageVersions"]),
        .library(name: "Navigation", targets: ["Navigation"]),
        .library(name: "PagePicker", targets: ["PagePicker"]),
        .library(name: "PageCover", targets: ["PageCover"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "VisualStyle"),
        .target(name: "NotesCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "PageTree", dependencies: ["NotesCore", "VisualStyle"]),
        // Тяжёлые модули (вложения, видео, напоминания, закладки) редактор видит только через протоколы фабрик
        // видов `BlockViewFactories`, которые передаёт приложение (plan.md, Structure Decision).
        .target(name: "PageEditor", dependencies: ["NotesCore", "VisualStyle", "EmojiPicker", "CodeHighlighting", "MathRendering"]),
        // Окно выбора эмодзи (FR-034): список и названия — из Unicode и CLDR (scripts/emoji/build-emoji-data.py).
        .target(name: "EmojiPicker", dependencies: ["VisualStyle"], resources: [.copy("Resources/emoji.tsv")]),
        .target(name: "PageSearch", dependencies: ["NotesCore", "VisualStyle", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "MarkdownExport", dependencies: ["NotesCore", "LinkPreview"]),
        // Импорт из Notion (US6): записи и журнал импортов (`import_run`) пишет прямо через GRDB, как поиск свой индекс.
        .target(name: "NotionImport", dependencies: ["NotesCore", "CodeHighlighting", "LinkPreview", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "Sync", dependencies: ["NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        // Состояния галереи для блоков 002 — из описателей типов редактора (`BlockKinds.gallerySamples`).
        .target(name: "UIGallery", dependencies: ["NotesCore", "PageEditor"]),
        .target(name: "ServiceLaunch"),
        // Подсветка кода (research R5): свой разборщик, без зависимостей.
        .target(name: "CodeHighlighting"),
        // Формулы (research R6): исходники SwiftMath 1.7.3 (MIT, `SwiftMath/LICENSE`) с одним шрифтом Latin Modern Math.
        // Код SwiftMath писан до Swift 6: режим языка 5, чтобы не переписывать чужие исходники.
        .target(name: "MathRendering", dependencies: ["VisualStyle"], exclude: ["SwiftMath/LICENSE"],
                resources: [.copy("SwiftMath/mathFonts.bundle")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        // Копии файлов на Mac, шифрование частей, отправка и докачка (research R9–R10).
        .target(name: "Attachments", dependencies: ["NotesCore", "Sync", .product(name: "GRDB", package: "GRDB.swift")]),
        // Закладки и обложки YouTube и Vimeo: один запрос при вставке (research R15, R8).
        .target(name: "LinkPreview"),
        // Индекс напоминаний и уведомления системы (research R11).
        .target(name: "Reminders", dependencies: ["NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        // Проигрыватель видеофайла и веб-проигрыватель YouTube и Vimeo по нажатию (research R8).
        .target(name: "EmbeddedMedia", dependencies: ["VisualStyle"]),
        // 003 (plan.md, Project Structure). Обратные ссылки: подписчик записи `page_link`, счёт и список (research R10).
        .target(name: "Backlinks", dependencies: ["NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        // История версий: снимки LZFSE, запись по отметкам, прореживание, разница, восстановление (research R11).
        .target(name: "PageVersions", dependencies: ["NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        // Вкладки окна и «назад/вперёд», хранение в `window_state`; без видов AppKit (research R5, R6).
        .target(name: "Navigation", dependencies: ["NotesCore"]),
        // Окно «Переместить в…» (research R9).
        .target(name: "PagePicker", dependencies: ["NotesCore", "PageSearch", "VisualStyle"]),
        // Обложка: вид, галерея, окно «Сменить обложку», «Переместить» (research R1).
        .target(name: "PageCover", dependencies: ["NotesCore", "Attachments", "VisualStyle"]),

        .testTarget(name: "VisualStyleTests", dependencies: ["VisualStyle"]),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "PageTreeTests", dependencies: ["PageTree"]),
        .testTarget(name: "PageEditorTests", dependencies: ["PageEditor", "NotesCore", "EmojiPicker"]),
        .testTarget(name: "EmojiPickerTests", dependencies: ["EmojiPicker", "NotesCore"]),
        .testTarget(name: "PageSearchTests", dependencies: ["PageSearch", "NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "MarkdownExportTests", dependencies: ["MarkdownExport", "NotesCore"]),
        .testTarget(name: "NotionImportTests", dependencies: ["NotionImport", "NotesCore", "MarkdownExport", "PageEditor", .product(name: "GRDB", package: "GRDB.swift")],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SyncTests", dependencies: ["Sync", "NotesCore", "Reminders", "Attachments", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "UIGalleryTests", dependencies: ["UIGallery", "NotesCore", "PageEditor"]),
        .testTarget(name: "ServiceLaunchTests", dependencies: ["ServiceLaunch"]),
        .testTarget(name: "CodeHighlightingTests", dependencies: ["CodeHighlighting"]),
        .testTarget(name: "MathRenderingTests", dependencies: ["MathRendering"]),
        .testTarget(name: "AttachmentsTests", dependencies: ["Attachments", "NotesCore", "Sync", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "LinkPreviewTests", dependencies: ["LinkPreview"]),
        .testTarget(name: "RemindersTests", dependencies: ["Reminders", "NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "EmbeddedMediaTests", dependencies: ["EmbeddedMedia"]),
        .testTarget(name: "BacklinksTests", dependencies: ["Backlinks", "NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "PageVersionsTests", dependencies: ["PageVersions", "NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "NavigationTests", dependencies: ["Navigation", "NotesCore"]),
        .testTarget(name: "PagePickerTests", dependencies: ["PagePicker", "NotesCore"]),
        .testTarget(name: "PageCoverTests", dependencies: ["PageCover", "NotesCore", "Attachments"]),
    ],
    swiftLanguageModes: [.v6]
)
