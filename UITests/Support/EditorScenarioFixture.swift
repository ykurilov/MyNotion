import Foundation
import NotesCore
import XCTest

/// Готовые страницы создаются через модель до запуска приложения: ни набора, ни автокоррекции.
enum EditorScenarioFixture {
    static let title = "Моя информация"
    static let coveredTitle = "Моя информация: длинное название страницы для проверки переноса при изменении ширины окна"
    static let otherTitle = "Другая страница"
    static let texts = ["Блок с текстом: заголовок 1", "Обычный текст для проверки наведения.", "fdfds", "fdsfsd", "dsa"]

    static func library(for test: XCTestCase, covered: Bool = false) throws -> UITestLibrary {
        let library = try UITestLibrary.make(for: test)
        let store = NotesStore(database: try AppDatabase.open(at: library.databaseURL),
                               clock: HybridLogicalClock(deviceId: UUID()))
        let pageId = try store.write { tx in
            var page = try tx.createPage(title: covered ? coveredTitle : title, icon: covered ? "🥰" : nil)
            if covered {
                page.cover = PageCover(source: .gallery("solid_blue"))
                try tx.updatePage(page)
            }
            for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            for (index, text) in texts.enumerated() {
                key = .between(key, nil)
                try tx.insertBlock(Block(pageId: page.id, kind: index == 0 ? .heading2 : index == 1 ? .paragraph : .bulletItem,
                                         text: InlineText(text), sortKey: key!))
            }
            if covered {
                for index in 0..<80 {
                    key = .between(key, nil)
                    try tx.insertBlock(Block(pageId: page.id, text: InlineText("Абзац \(index + 1): текст для проверки прокрутки страницы с обложкой."), sortKey: key!))
                }
            }
            _ = try tx.createPage(title: otherTitle)
            return page.id
        }
        try store.saveWindowState(WindowState(windowId: WindowState.mainWindowId, openPageId: pageId))
        return library
    }
}
