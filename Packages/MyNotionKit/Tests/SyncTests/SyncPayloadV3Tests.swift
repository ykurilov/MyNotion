import CryptoKit
import Foundation
import Testing
@testable import NotesCore
@testable import Sync

/// Пачка `formatVersion: 3` (contracts/sync-v3-and-export.md): новые поля страницы; пачки v2 читаются,
/// Mac с форматом 2 пачку v3 не применяет.
@MainActor
@Suite("Формат пачки v3")
struct SyncPayloadV3Tests {
    let hlc = HybridTimestamp(wallMillis: 1_760_000_000_000, counter: 1, deviceId: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)
    let pageId = UUID(uuidString: "0193A1B2-0000-7000-8000-000000000003")!
    let ref = AttachmentRef(id: UUID(uuidString: "0193A1B2-0000-7000-8000-0000000000F1")!, name: "Обложка.jpg", byteCount: 20_000_000,
                            contentType: "public.jpeg", sha256: String(repeating: "c", count: 64))

    /// «поле значение» — как их пишет пачка (ключи по алфавиту, `value` — последний).
    private func encoded(_ value: SyncChange.Value) throws -> String {
        let change = SyncChange(entity: .page, id: pageId, value: value, hlc: hlc)
        let text = String(decoding: try SyncJSON.encoder().encode(change), as: UTF8.self)
        #expect(try SyncJSON.decoder().decode(SyncChange.self, from: Data(text.utf8)) == change, "\(value.field) переживает пачку")
        guard let field = text.range(of: #""field":"#), let valueStart = text.range(of: #","value":"#) else { return text }
        let fieldName = text[field.upperBound...].split(separator: "\"")[0]
        return "\(fieldName) {\"value\":" + text[valueStart.upperBound...]
    }

    @Test("Версия формата — 3")
    func formatVersion() {
        #expect(SyncBatch.currentFormatVersion == 3)
        #expect(SyncBatch(deviceId: "d", deviceName: "Mac", changes: []).formatVersion == 3)
        #expect(SyncSnapshot(seq: 1, changes: [], knowledge: ClockKnowledge()).formatVersion == 3)
    }

    @Test("Значения новых полей страницы — дословно как в контракте")
    func newPageFieldsMatchContract() throws {
        #expect(try encoded(.cover(nil)) == #"cover {"value":null}"#)
        #expect(try encoded(.cover(PageCover(source: .gallery("gradients_3")))) == #"cover {"value":{"offset":0.5,"source":{"gallery":"gradients_3"}}}"#)
        let file = try encoded(.cover(PageCover(source: .file(ref), offset: 0.42)))
        #expect(file.hasPrefix(#"cover {"value":{"offset":0.42,"source":{"file":{"#))
        #expect(try encoded(.isFullWidth(true)) == #"isFullWidth {"value":true}"#)
        #expect(try encoded(.isSmallText(false)) == #"isSmallText {"value":false}"#)
        #expect(try encoded(.favorite(nil)) == #"favorite {"value":null}"#)
        #expect(try encoded(.favorite("a0V")) == #"favorite {"value":"a0V"}"#)
        #expect(try encoded(.visitedAt(nil)) == #"visitedAt {"value":null}"#)
        let visit = try Date("2026-10-20T09:15:03.120Z", strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        #expect(try encoded(.visitedAt(visit)) == #"visitedAt {"value":"2026-10-20T09:15:03.120Z"}"#)
        #expect(try encoded(.isTemplate(true)) == #"isTemplate {"value":true}"#)
    }

    @Test("Сдвиг обложки урезается к 0…1, неизвестный id галереи хранится как есть")
    func coverValuesFromNewerMacs() throws {
        let json = #"{"entity":"page","field":"cover","hlc":"\#(hlc)","id":"\#(pageId)","value":{"offset":7,"source":{"gallery":"future_9"}}}"#
        let change = try SyncJSON.decoder().decode(SyncChange.self, from: Data(json.utf8))
        #expect(change.value == .cover(PageCover(source: .gallery("future_9"), offset: 1)))
    }

    @Test("Пачка v2 читается как раньше")
    func readsV2Batch() throws {
        let key = SymmetricKey(size: .bits256)
        let change = SyncChange(entity: .page, id: pageId, value: .title("Старая пачка"), hlc: hlc)
        let sealed = try BatchCipher(key: key).seal(SyncBatch(formatVersion: 2, deviceId: "d", deviceName: "Mac", changes: [change]), batchId: "b2")
        let opened = try BatchCipher(key: key).open(sealed, batchId: "b2", deviceId: "d")
        #expect(opened.formatVersion == 2 && opened.changes == [change])
    }

    @Test("Mac с форматом 2 пачку v3 не применяет и показывает «Обновите MyNotion на этом Mac»")
    func olderMacWaits() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try BatchCipher(key: key).seal(SyncBatch(deviceId: "d", deviceName: "Mac", changes: [
            SyncChange(entity: .page, id: pageId, value: .isTemplate(true), hlc: hlc),
        ]), batchId: "b3")
        #expect(throws: BatchCipherError.newerFormat(3)) {
            try BatchCipher(key: key, supportedFormatVersion: 2).open(sealed, batchId: "b3", deviceId: "d")
        }
        #expect(BatchCipherError.newerFormat(3).errorDescription?.localizedCaseInsensitiveContains("Обновите MyNotion на этом Mac") == true)
    }

    @Test("Исходящие поля страницы: шесть новых полей со своими метками")
    func outgoingPageFields() throws {
        let mac = try SyncTestMac(name: "Mac", wallMillis: 10_000)
        let id = try mac.store.write { try $0.createPage(title: "Поля").id }
        _ = try mac.takeOutgoing()
        mac.wall.set(20_000)
        try mac.store.write { tx in
            var page = try #require(try tx.page(id))
            page.cover = PageCover(source: .gallery("solid_red"))
            page.isFullWidth = true
            page.isSmallText = true
            page.favorite = FractionalSortKey(rawValue: "m")
            page.visitedAt = Date(timeIntervalSince1970: 1_790_000_000)
            page.isTemplate = true
            try tx.updatePage(page)
        }
        let fields = Set(try mac.takeOutgoing().flatMap(\.changes).filter { $0.id == id }.map(\.value.field))
        #expect(fields == ["cover", "isFullWidth", "isSmallText", "favorite", "visitedAt", "isTemplate"])
    }
}
