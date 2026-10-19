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
        .target(name: "MarkdownExport", dependencies: ["NotesCore"]),
        // Импорт из Notion (US6): записи и журнал импортов (`import_run`) пишет прямо через GRDB, как поиск свой индекс.
        .target(name: "NotionImport", dependencies: ["NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "Sync", dependencies: ["NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "UIGallery", dependencies: ["NotesCore"]),
        .target(name: "ServiceLaunch"),
        // Подсветка кода (research R5): свой разборщик, без зависимостей.
        .target(name: "CodeHighlighting"),
        // Формулы (research R6): исходники SwiftMath (MIT); шрифт Latin Modern Math ресурсом добавляет этап US4.
        .target(name: "MathRendering"),
        // Копии файлов на Mac, шифрование частей, отправка и докачка (research R9–R10).
        .target(name: "Attachments", dependencies: ["NotesCore", "Sync", .product(name: "GRDB", package: "GRDB.swift")]),
        // Закладки и обложки YouTube и Vimeo: один запрос при вставке (research R15, R8).
        .target(name: "LinkPreview"),
        // Индекс напоминаний и уведомления системы (research R11).
        .target(name: "Reminders", dependencies: ["NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        // Проигрыватель видеофайла и веб-проигрыватель YouTube и Vimeo по нажатию (research R8).
        .target(name: "EmbeddedMedia", dependencies: ["VisualStyle"]),

        .testTarget(name: "VisualStyleTests", dependencies: ["VisualStyle"]),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "PageTreeTests", dependencies: ["PageTree"]),
        .testTarget(name: "PageEditorTests", dependencies: ["PageEditor", "NotesCore", "EmojiPicker"]),
        .testTarget(name: "EmojiPickerTests", dependencies: ["EmojiPicker", "NotesCore"]),
        .testTarget(name: "PageSearchTests", dependencies: ["PageSearch", "NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "MarkdownExportTests", dependencies: ["MarkdownExport", "NotesCore"]),
        .testTarget(name: "NotionImportTests", dependencies: ["NotionImport", "NotesCore", "MarkdownExport", .product(name: "GRDB", package: "GRDB.swift")],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SyncTests", dependencies: ["Sync", "NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "UIGalleryTests", dependencies: ["UIGallery", "NotesCore"]),
        .testTarget(name: "ServiceLaunchTests", dependencies: ["ServiceLaunch"]),
        .testTarget(name: "CodeHighlightingTests", dependencies: ["CodeHighlighting"]),
        .testTarget(name: "MathRenderingTests", dependencies: ["MathRendering"]),
        .testTarget(name: "AttachmentsTests", dependencies: ["Attachments", "NotesCore", "Sync", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "LinkPreviewTests", dependencies: ["LinkPreview"]),
        .testTarget(name: "RemindersTests", dependencies: ["Reminders", "NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "EmbeddedMediaTests", dependencies: ["EmbeddedMedia"]),
    ],
    swiftLanguageModes: [.v6]
)
