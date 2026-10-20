import Foundation
import Testing
@testable import NotesCore

/// Быстрое чтение меток полей из базы (research R15, п. 2: разбор JSONDecoder'ом — половина чтения «богатой» страницы):
/// результат тот же, что у JSONDecoder; непривычная запись читается JSONDecoder'ом.
@Suite("Чтение меток полей")
struct FieldClocksDecodingTests {
    let device = UUID()

    @Test("Запись базы читается так же, как JSONDecoder'ом; неизвестные поля пропускаются")
    func sameAsDecoder() throws {
        let a = HybridTimestamp(wallMillis: 1_760_000_000_000, counter: 3, deviceId: device)
        let b = HybridTimestamp(wallMillis: 1_760_000_000_001, counter: 0, deviceId: device)
        let block = BlockFieldClocks(kindAndIndent: a, text: b, placement: a, props: b)
        let text = block.databaseJSON
        #expect(try BlockFieldClocks(databaseJSON: text) == JSONDecoder().decode(BlockFieldClocks.self, from: Data(text.utf8)))
        #expect(try BlockFieldClocks(databaseJSON: text) == block)
        var page = PageFieldClocks(title: a, icon: b)
        page.cover = b
        page.favorite = a
        #expect(try PageFieldClocks(databaseJSON: page.databaseJSON) == page)
        #expect(try BlockFieldClocks(databaseJSON: #"{"future":"\#(a)","text":"\#(b)"}"#) == BlockFieldClocks(text: b))
        #expect(try BlockFieldClocks(databaseJSON: "{}") == BlockFieldClocks())
    }

    @Test("Пробелы, переводы строк и экранирование — через JSONDecoder; испорченная запись — ошибка")
    func fallsBackToDecoder() throws {
        let a = HybridTimestamp(wallMillis: 1_760_000_000_000, counter: 3, deviceId: device)
        #expect(try BlockFieldClocks(databaseJSON: "{ \"text\" : \"\(a)\" }") == BlockFieldClocks(text: a))
        #expect(throws: (any Error).self) { try BlockFieldClocks(databaseJSON: #"{"text":"не метка"}"#) }
        #expect(throws: (any Error).self) { try BlockFieldClocks(databaseJSON: #"{"text":"#) }
    }
}
