import Foundation
import Testing
@testable import NotesCore

@Suite("Оформление в строке 002")
struct InlineTextStylesTests {
    static let atom = "\u{FFFC}"
    let pageId = UUID()
    let date = DateMention(id: UUID(), start: "2026-10-20T09:00", includesTime: true, timeZone: "Asia/Makassar",
                           reminder: DateMention.Reminder(fireAt: Date(timeIntervalSince1970: 1_760_922_000)))

    @Test("textColor и backgroundColor — «один на символ (как link)»: побеждает последний, соседние сливаются")
    func colorsOnePerCharacter() {
        let text = InlineText("красный синий", runs: [
            StyledRun(start: 0, length: 13, style: .textColor(.red)),
            StyledRun(start: 8, length: 5, style: .textColor(.blue)),
            StyledRun(start: 0, length: 4, style: .backgroundColor(.yellow)),
            StyledRun(start: 4, length: 3, style: .backgroundColor(.yellow)),
        ]).normalized()
        #expect(text.runs == [
            StyledRun(start: 0, length: 8, style: .textColor(.red)),
            StyledRun(start: 0, length: 7, style: .backgroundColor(.yellow)),
            StyledRun(start: 8, length: 5, style: .textColor(.blue)),
        ])
    }

    @Test("mention, date, equation — «ровно на одном знаке U+FFFC»")
    func atomsOnObjectReplacementCharacter() {
        let pageLink = UUID()
        let string = "см. \(Self.atom), срок \(Self.atom), \(Self.atom)"
        let text = InlineText(string, runs: [
            StyledRun(start: 4, length: 1, style: .mention(pageLink)),
            StyledRun(start: 12, length: 1, style: .date(date)),
            StyledRun(start: 15, length: 1, style: .equation("E = mc^2")),
        ]).normalized()
        #expect(text.string == string)
        #expect(text.runs.count == 3)
        #expect(text.runs.allSatisfy { $0.length == 1 })
        // Атом, растянутый на несколько знаков, остаётся только на своём U+FFFC.
        let stretched = InlineText("а\(Self.atom)б", runs: [StyledRun(start: 0, length: 3, style: .mention(pageLink))]).normalized()
        #expect(stretched.runs == [StyledRun(start: 1, length: 1, style: .mention(pageLink))])
    }

    @Test("normalized() отбрасывает атом без U+FFFC и U+FFFC без атома")
    func normalizationDropsBrokenAtoms() {
        let noCharacter = InlineText("текст", runs: [StyledRun(start: 1, length: 1, style: .equation("x"))]).normalized()
        #expect(noCharacter == InlineText("текст"))

        // Лишний U+FFFC выпадает из текста, оформление после него сдвигается.
        let orphan = InlineText("а\(Self.atom)жирный", runs: [StyledRun(start: 2, length: 6, style: .bold)]).normalized()
        #expect(orphan == InlineText("ажирный", runs: [StyledRun(start: 1, length: 6, style: .bold)]))

        let mixed = InlineText("\(Self.atom)\(Self.atom)x", runs: [
            StyledRun(start: 1, length: 1, style: .mention(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)),
            StyledRun(start: 0, length: 3, style: .italic),
        ]).normalized()
        #expect(mixed.string == "\(Self.atom)x")
        #expect(mixed.runs == [
            StyledRun(start: 0, length: 2, style: .italic),
            StyledRun(start: 0, length: 1, style: .mention(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)),
        ])
    }

    @Test("Кодирование JSON — по contracts/sync-and-files-api.md")
    func jsonEncoding() throws {
        let pageLink = UUID(uuidString: "0193A1B2-0000-7000-8000-000000000001")!
        let runs = [
            StyledRun(start: 0, length: 2, style: .textColor(.red)),
            StyledRun(start: 0, length: 2, style: .backgroundColor(.yellow)),
            StyledRun(start: 2, length: 1, style: .mention(pageLink)),
            StyledRun(start: 3, length: 1, style: .date(date)),
            StyledRun(start: 4, length: 1, style: .equation("\\frac{1}{2}")),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try runs.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        #expect(json[0] == #"{"color":"red","length":2,"start":0,"style":"textColor"}"#)
        #expect(json[1] == #"{"color":"yellow","length":2,"start":0,"style":"backgroundColor"}"#)
        #expect(json[2] == #"{"length":1,"pageId":"0193A1B2-0000-7000-8000-000000000001","start":2,"style":"mention"}"#)
        #expect(json[3] == """
            {"date":{"id":"\(date.id.uuidString)","includesTime":true,"reminder":{"fireAt":"2025-10-20T01:00:00Z"},\
            "start":"2026-10-20T09:00","timeZone":"Asia/Makassar"},"length":1,"start":3,"style":"date"}
            """)
        #expect(json[4] == #"{"latex":"\\frac{1}{2}","length":1,"start":4,"style":"equation"}"#)
        let decoded = try json.map { try JSONDecoder().decode(StyledRun.self, from: Data($0.utf8)) }
        #expect(decoded == runs)

        let withoutReminder = DateMention(id: UUID(), start: "2026-10-20", includesTime: false, timeZone: "Europe/Moscow")
        let encoded = String(decoding: try encoder.encode(withoutReminder), as: UTF8.self)
        #expect(!encoded.contains("reminder"))
        #expect(try JSONDecoder().decode(DateMention.self, from: Data(encoded.utf8)) == withoutReminder)
    }

    @Test("Все 9 цветов Notion, «по умолчанию» — отсутствие цвета")
    func notionColors() {
        #expect(NotionColor.allCases.map(\.rawValue) == ["gray", "brown", "orange", "yellow", "green", "blue", "purple", "pink", "red"])
    }

    @Test("Блок с новыми оформлениями записывается и читается из базы без изменений")
    func storedRoundTrip() throws {
        let folder = try TemporaryFolder()
        let store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        let text = InlineText("цвет \(Self.atom) \(Self.atom)", runs: [
            StyledRun(start: 0, length: 4, style: .textColor(.purple)),
            StyledRun(start: 5, length: 1, style: .mention(UUID())),
            StyledRun(start: 7, length: 1, style: .date(date)),
        ]).normalized()
        let (pageId, blockId) = try store.write { tx in
            let page = try tx.createPage(title: "Оформление")
            var block = try tx.blocks(ofPage: page.id)[0]
            block.text = text
            try tx.updateBlock(block)
            return (page.id, block.id)
        }
        #expect(try store.pageContent(pageId)?.blocks.first { $0.id == blockId }?.text == text)
    }
}
