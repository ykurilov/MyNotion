import AppKit
import NotesCore

/// Место пункта в меню «•••» страницы (contracts/pages-ui.md, «Меню «•••» страницы»): порядок и группы.
/// Меню собирается из описателей (`PageMenuItem`): каждая история добавляет свой файл в `App/MainWindow/PageMenu/`.
public enum PageMenuSlot: Int, CaseIterable, Comparable, Sendable {
    case findAction, duplicate, moveTo, versionHistory
    case appearance
    case template, trash
    case footer

    /// Группа: между группами — линия.
    var group: Int {
        switch self {
        case .findAction, .duplicate, .moveTo, .versionHistory: 0
        case .appearance: 1
        case .template, .trash: 2
        case .footer: 3
        }
    }

    public static func < (lhs: PageMenuSlot, rhs: PageMenuSlot) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Что пункт меню знает о странице.
public struct PageMenuContext {
    public let page: Page
    public let wordCount: Int

    public init(page: Page, wordCount: Int) {
        self.page = page
        self.wordCount = wordCount
    }
}

/// Описатель пункта меню «•••».
@MainActor
public struct PageMenuItem {
    public enum Kind {
        /// Обычный пункт; `shortcut` — подпись клавиш справа.
        case action(_ perform: @MainActor (PageMenuContext) -> Void, shortcut: String? = nil)
        /// Подменю с переключателями (US1, «Вид страницы»).
        case toggles([PageMenuToggle])
        /// Поле «Найти действие…»: сужает меню до пунктов с запросом в названии.
        case search
        /// Серая строка внизу.
        case footer
    }

    public let slot: PageMenuSlot
    public let title: @MainActor (PageMenuContext) -> String
    public let isShown: @MainActor (PageMenuContext) -> Bool
    public let kind: Kind

    public init(slot: PageMenuSlot, title: @escaping @MainActor (PageMenuContext) -> String,
                isShown: @escaping @MainActor (PageMenuContext) -> Bool = { _ in true }, kind: Kind) {
        self.slot = slot
        self.title = title
        self.isShown = isShown
        self.kind = kind
    }

    public static func action(_ slot: PageMenuSlot, _ title: String, perform: @escaping @MainActor (PageMenuContext) -> Void) -> PageMenuItem {
        PageMenuItem(slot: slot, title: { _ in title }, kind: .action(perform))
    }
}

/// Переключатель подменю.
@MainActor
public struct PageMenuToggle {
    public let title: String
    public let isOn: @MainActor (PageMenuContext) -> Bool
    public let toggle: @MainActor (PageMenuContext) -> Void

    public init(title: String, isOn: @escaping @MainActor (PageMenuContext) -> Bool, toggle: @escaping @MainActor (PageMenuContext) -> Void) {
        self.title = title
        self.isOn = isOn
        self.toggle = toggle
    }
}

/// Строка собранного меню.
@MainActor
public enum PageMenuRow {
    case item(PageMenuItem)
    case separator
}

/// Порядок меню: по местам; между группами — линия, пустые группы и скрытые пункты места не занимают.
@MainActor
public enum PageMenuLayout {
    public static func rows(_ items: [PageMenuItem], context: PageMenuContext) -> [PageMenuRow] {
        var rows: [PageMenuRow] = []
        var lastGroup: Int?
        for item in items.filter({ $0.isShown(context) }).sorted(by: { $0.slot < $1.slot }) {
            if let lastGroup, lastGroup != item.slot.group { rows.append(.separator) }
            lastGroup = item.slot.group
            rows.append(.item(item))
        }
        return rows
    }
}

/// Подвал меню: «Изменено: сегодня в 18:25, N слов».
public enum PageMenuFooter {
    public static func text(for context: PageMenuContext, now: Date = Date()) -> String {
        "Изменено: \(changed(context.page.updatedAt, now: now)), \(words(context.wordCount))"
    }

    static func changed(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "ru_RU")))
        if calendar.isDate(date, inSameDayAs: now) { return "сегодня в \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "вчера в \(time)"
        }
        return date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "ru_RU")))
    }

    /// «1 слово», «3 слова», «11 слов».
    static func words(_ count: Int) -> String {
        let lastTwo = count % 100, last = count % 10
        let word = (11...14).contains(lastTwo) ? "слов" : last == 1 ? "слово" : (2...4).contains(last) ? "слова" : "слов"
        return "\(count) \(word)"
    }

    /// Слова страницы: название и текст блоков.
    @MainActor public static func wordCount(of document: PageDocument) -> Int {
        ([document.page.title] + document.blocks.map(\.text.string)).reduce(0) { total, text in
            total + text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        }
    }
}
