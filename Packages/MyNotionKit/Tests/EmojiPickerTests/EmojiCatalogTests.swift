import Foundation
import Testing
@testable import EmojiPicker
@testable import NotesCore

/// Список эмодзи окна выбора иконки (FR-034): из Unicode `emoji-test.txt`, названия для поиска — из CLDR (ru и en).
@Suite("Каталог эмодзи")
struct EmojiCatalogTests {
    let catalog = EmojiCatalog.shared

    @Test("Восемь разделов Unicode по порядку, в каждом есть эмодзи; без оттенков кожи")
    func sections() {
        #expect(EmojiSection.allCases.map(\.title) == [
            "Недавние", "Смайлы и люди", "Животные и природа", "Еда", "Занятия", "Путешествия", "Предметы", "Символы", "Флаги",
        ])
        for section in EmojiSection.allCases where section != .recent {
            #expect(!catalog.emojis(in: section).isEmpty, "Пустой раздел \(section.title)")
        }
        #expect(catalog.all.count > 1_800)
        #expect(catalog.emojis(in: .people).first?.character == "😀")
        #expect(catalog.emoji("📘")?.section == .objects)
        #expect(!catalog.all.contains { $0.character.unicodeScalars.contains { (0x1F3FB...0x1F3FF).contains($0.value) } })
    }

    @Test("Каждый эмодзи годится в иконку страницы: один знак-эмодзи")
    func everyEmojiIsValidIcon() {
        let invalid = catalog.all.map(\.character).filter { !NotesTransaction.isSingleEmoji($0) }
        #expect(invalid.isEmpty, "Не годятся: \(invalid.prefix(20))")
    }

    @Test("Поиск по русским и английским названиям и словам, ё как е, по началу слов")
    func search() {
        #expect(catalog.search("кот").map(\.character).contains("🐱"))
        #expect(catalog.search("Cat").map(\.character).contains("🐱"))
        #expect(catalog.search("синяя книга").first?.character == "📘")
        #expect(catalog.search("blue book").first?.character == "📘")
        #expect(catalog.search("еж").map(\.character).contains("🦔"))
        #expect(catalog.search("ёж").map(\.character).contains("🦔"))
        #expect(catalog.search("  ").isEmpty)
        #expect(catalog.search("щщщщ").isEmpty)
    }

    @Test("Сначала те, чьё название начинается с запроса")
    func searchRanking() {
        let results = catalog.search("сердце").prefix(3).map(\.russianName)
        #expect(results.allSatisfy { $0.hasPrefix("сердце") }, "\(results)")
    }

    @Test("Случайная — из каталога")
    func random() {
        var generator = SystemRandomNumberGenerator()
        #expect(catalog.emoji(catalog.random(using: &generator).character) != nil)
    }
}

@Suite("Недавние эмодзи")
struct RecentEmojisTests {
    private func makeRecents() -> RecentEmojis {
        let defaults = UserDefaults(suiteName: "RecentEmojisTests-\(UUID())")!
        return RecentEmojis(defaults: defaults)
    }

    @Test("Последний выбранный — первым, без повторов, не больше 16")
    func keepsLastSixteen() {
        let recents = makeRecents()
        #expect(recents.emojis.isEmpty)
        recents.add("📘")
        recents.add("🌿")
        recents.add("📘")
        #expect(recents.emojis == ["📘", "🌿"])
        let many = EmojiCatalog.shared.emojis(in: .food).prefix(20).map(\.character)
        many.forEach(recents.add)
        #expect(recents.emojis.count == RecentEmojis.limit)
        #expect(RecentEmojis.limit == 16)
        #expect(recents.emojis.first == many.last)
    }
}
