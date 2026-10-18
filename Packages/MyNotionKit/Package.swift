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
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "VisualStyle"),
        .target(name: "NotesCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "PageTree", dependencies: ["NotesCore", "VisualStyle"]),
        .target(name: "PageEditor", dependencies: ["NotesCore", "VisualStyle", "EmojiPicker"]),
        // Окно выбора эмодзи (FR-034): список и названия — из Unicode и CLDR (scripts/emoji/build-emoji-data.py).
        .target(name: "EmojiPicker", dependencies: ["VisualStyle"], resources: [.copy("Resources/emoji.tsv")]),
        .target(name: "PageSearch", dependencies: ["NotesCore", "VisualStyle", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "MarkdownExport", dependencies: ["NotesCore"]),
        .target(name: "NotionImport", dependencies: ["NotesCore"]),
        .target(name: "Sync", dependencies: ["NotesCore"]),
        .target(name: "UIGallery", dependencies: ["NotesCore"]),
        .target(name: "ServiceLaunch"),

        .testTarget(name: "VisualStyleTests", dependencies: ["VisualStyle"]),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "PageTreeTests", dependencies: ["PageTree"]),
        .testTarget(name: "PageEditorTests", dependencies: ["PageEditor", "NotesCore", "EmojiPicker"]),
        .testTarget(name: "EmojiPickerTests", dependencies: ["EmojiPicker", "NotesCore"]),
        .testTarget(name: "PageSearchTests", dependencies: ["PageSearch", "NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "MarkdownExportTests", dependencies: ["MarkdownExport", "NotesCore"]),
        .testTarget(name: "NotionImportTests", dependencies: ["NotionImport"]),
        .testTarget(name: "SyncTests", dependencies: ["Sync"]),
        .testTarget(name: "UIGalleryTests", dependencies: ["UIGallery", "NotesCore"]),
        .testTarget(name: "ServiceLaunchTests", dependencies: ["ServiceLaunch"]),
    ],
    swiftLanguageModes: [.v6]
)
