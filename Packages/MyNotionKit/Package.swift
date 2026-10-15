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
        .library(name: "PageSearch", targets: ["PageSearch"]),
        .library(name: "MarkdownExport", targets: ["MarkdownExport"]),
        .library(name: "NotionImport", targets: ["NotionImport"]),
        .library(name: "Sync", targets: ["Sync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "VisualStyle"),
        .target(name: "NotesCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "PageTree", dependencies: ["NotesCore", "VisualStyle"]),
        .target(name: "PageEditor", dependencies: ["NotesCore", "VisualStyle"]),
        .target(name: "PageSearch", dependencies: ["NotesCore", "VisualStyle"]),
        .target(name: "MarkdownExport", dependencies: ["NotesCore"]),
        .target(name: "NotionImport", dependencies: ["NotesCore"]),
        .target(name: "Sync", dependencies: ["NotesCore"]),

        .testTarget(name: "VisualStyleTests", dependencies: ["VisualStyle"]),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "PageTreeTests", dependencies: ["PageTree"]),
        .testTarget(name: "PageEditorTests", dependencies: ["PageEditor", "NotesCore"]),
        .testTarget(name: "PageSearchTests", dependencies: ["PageSearch"]),
        .testTarget(name: "MarkdownExportTests", dependencies: ["MarkdownExport"]),
        .testTarget(name: "NotionImportTests", dependencies: ["NotionImport"]),
        .testTarget(name: "SyncTests", dependencies: ["Sync"]),
    ],
    swiftLanguageModes: [.v6]
)
