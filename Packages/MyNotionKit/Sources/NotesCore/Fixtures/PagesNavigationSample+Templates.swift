import Foundation

extension PagesNavigationSample {
    public static let meetingTemplateTitle = "Шаблон: заметки встречи"

    /// US7: 3 шаблона в корне. «Заметки встречи» — с тремя подстраницами и датой «@сегодня» в тексте
    /// (в копии станет днём создания); остальные — с парой строк.
    static let templates: Part? = Part(title: meetingTemplateTitle) { tx, _ in
        /// Заменяет стартовый пустой абзац блоками по порядку.
        func writeBody(_ pageId: UUID, _ blocks: () -> [Block]) throws {
            for block in try tx.blocks(ofPage: pageId) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            for var block in blocks() {
                key = .between(key, nil)
                block.sortKey = key!
                try tx.insertBlock(block)
            }
        }
        func makeTemplate(_ title: String, icon: String) throws -> Page {
            var page = try tx.createPage(title: title, icon: icon)
            page.isTemplate = true
            return try tx.updatePage(page)
        }

        let meeting = try makeTemplate(meetingTemplateTitle, icon: "🗓️")
        var subpages: [Page] = []
        for title in ["Повестка", "Итоги", "Задачи после встречи"] {
            subpages.append(try tx.createPage(title: title, parentId: meeting.id))
        }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let today = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        let date = DateMention(start: today, includesTime: false, timeZone: TimeZone.current.identifier, templateRelative: .today)
        let marker = String(UnicodeScalar(InlineText.objectReplacementCharacter)!)
        let dateLine = "Дата встречи: \(marker)"
        try writeBody(meeting.id) {
            [
                Block(pageId: meeting.id, kind: .paragraph, text: InlineText(dateLine, runs: [
                    StyledRun(start: (dateLine as NSString).length - 1, length: 1, style: .date(date)),
                ]), sortKey: .between(nil, nil)),
                Block(pageId: meeting.id, kind: .paragraph, text: InlineText("Участники:"), sortKey: .between(nil, nil)),
            ] + subpages.map { Block(pageId: meeting.id, kind: .pageLink, linkedPageId: $0.id, sortKey: .between(nil, nil)) }
        }

        let weekly = try makeTemplate("Шаблон: план на неделю", icon: "📅")
        try writeBody(weekly.id) {
            [Block(pageId: weekly.id, kind: .heading2, text: InlineText("Главное на неделю"), sortKey: .between(nil, nil)),
             Block(pageId: weekly.id, kind: .checkbox, text: InlineText("Первая задача"), sortKey: .between(nil, nil))]
        }
        let diary = try makeTemplate("Шаблон: дневник", icon: "📔")
        try writeBody(diary.id) {
            [Block(pageId: diary.id, kind: .paragraph, text: InlineText("Как прошёл день:"), sortKey: .between(nil, nil))]
        }
    }
}
