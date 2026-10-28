import Foundation
import GRDB
import Synchronization
import Testing
@testable import AIChatHistory
@testable import NotesCore

/// Пустая папка на время теста; стирается вместе с объектом.
final class TemporaryFolder: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("AIChatHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Системные часы под управлением теста.
final class WallClock: Sendable {
    private let millis: Mutex<Int64>

    init(_ millis: Int64) { self.millis = Mutex(millis) }

    func set(_ value: Int64) { millis.withLock { $0 = value } }

    var reading: @Sendable () -> Int64 { { [self] in millis.withLock { $0 } } }
}

/// Устройство с базой заметок и часами под управлением теста.
final class ChatDevice {
    let folder: TemporaryFolder
    let wall: WallClock
    let notes: NotesStore
    let chats: AIChatStore

    init(wallMillis: Int64 = 10_000) throws {
        folder = try TemporaryFolder()
        wall = WallClock(wallMillis)
        notes = NotesStore(database: try AppDatabase.open(at: folder.url.appendingPathComponent("MyNotion.sqlite")),
                           clock: HybridLogicalClock(deviceId: UUID(), wallClock: wall.reading))
        chats = AIChatStore(store: notes)
    }

    func setWall(_ millis: Int64) { wall.set(millis) }

    func pending() throws -> AIChatSync.Pending? { try AIChatSync.pending(in: notes) }

    /// Отправить всё отмеченное, как цикл синхронизации: порциями, пока есть что слать.
    func sendAll() throws -> [AIChatSyncRecord] {
        var sent: [AIChatSyncRecord] = []
        while let pending = try pending() {
            sent += pending.records
            try AIChatSync.didSend(pending, in: notes)
        }
        return sent
    }

    @discardableResult
    func receive(_ records: [AIChatSyncRecord]?, requestedByOthers: Bool = false) throws -> Bool {
        try notes.write { try AIChatSync.merge(records, requestedByOthers: requestedByOthers, in: $0) }
    }
}

private let date = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("Чаты ИИ-агента в базе заметок")
struct AIChatStoreTests {
    @Test("Новый чат с сообщениями: порядок сообщений, список чатов — свежий сверху")
    func createAndAppend() throws {
        let device = try ChatDevice()
        let first = try device.chats.createChat(title: "План отпуска", at: date)
        let second = try device.chats.createChat(title: "Задачи", at: date.addingTimeInterval(10))
        try device.chats.append(#"{"kind":"user"}"#, id: UUID(), to: first.id, at: date.addingTimeInterval(20))
        try device.chats.append(#"{"kind":"assistant"}"#, id: UUID(), to: first.id, at: date.addingTimeInterval(21))

        #expect(try device.chats.chats().map(\.title) == ["План отпуска", "Задачи"], "Чат с новым сообщением поднялся наверх")
        let messages = try device.chats.messages(in: first.id)
        #expect(messages.map(\.body) == [#"{"kind":"user"}"#, #"{"kind":"assistant"}"#])
        #expect(messages.map(\.position) == [0, 1])
        #expect(try device.chats.messages(in: second.id).isEmpty)
        #expect(try device.chats.chat(first.id)?.updatedAt == date.addingTimeInterval(21))
    }

    @Test("Переименование меняет название; повтор того же сообщения не дублирует его")
    func renameAndIdempotentAppend() throws {
        let device = try ChatDevice()
        let chat = try device.chats.createChat(title: "Новый чат", at: date)
        try device.chats.rename(chat.id, to: "Итоги недели")
        let id = UUID()
        try device.chats.append("a", id: id, to: chat.id, at: date)
        try device.chats.append("a", id: id, to: chat.id, at: date)
        #expect(try device.chats.chat(chat.id)?.title == "Итоги недели")
        #expect(try device.chats.messages(in: chat.id).count == 1)
    }

    @Test("Изменение чатов будит подписчиков")
    func notifies() async throws {
        let device = try ChatDevice()
        let counter = Mutex(0)
        let observer = NotificationCenter.default.addObserver(forName: AIChatStore.didChange, object: nil, queue: nil) { _ in
            counter.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let chat = try device.chats.createChat(title: "Чат", at: date)
        try device.chats.append("a", id: UUID(), to: chat.id, at: date)
        #expect(counter.withLock { $0 } >= 2)
    }
}

@Suite("Синхронизация чатов ИИ-агента")
struct AIChatSyncTests {
    @Test("Новый чат уходит заголовком и сообщениями; после отправки отправлять нечего")
    func pendingThenSent() throws {
        let device = try ChatDevice()
        let chat = try device.chats.createChat(title: "План", at: date)
        try device.chats.append("one", id: UUID(), to: chat.id, at: date)
        try device.chats.append("two", id: UUID(), to: chat.id, at: date)

        let pending = try #require(try device.pending())
        #expect(pending.request == nil)
        let record = try #require(pending.records.first)
        #expect(pending.records.count == 1)
        #expect(record.id == chat.id)
        #expect(record.title == "План")
        #expect(record.messages.map(\.body) == ["one", "two"])
        try AIChatSync.didSend(pending, in: device.notes)
        #expect(try device.pending() == nil)

        try device.chats.append("three", id: UUID(), to: chat.id, at: date.addingTimeInterval(5))
        let next = try #require(try device.pending())
        #expect(next.records.first?.messages.map(\.body) == ["three"], "Уходят только новые сообщения, заголовок — с ними")
        #expect(next.records.first?.updatedAt == date.addingTimeInterval(5))
    }

    @Test("Правка во время отправки не теряется: отметка остаётся до следующей пачки")
    func editDuringSend() throws {
        let device = try ChatDevice()
        let chat = try device.chats.createChat(title: "Старое", at: date)
        let pending = try #require(try device.pending())
        device.setWall(20_000)
        try device.chats.rename(chat.id, to: "Новое")
        try AIChatSync.didSend(pending, in: device.notes)
        #expect(try device.pending()?.records.first?.title == "Новое")
    }

    @Test("Большой чат уходит порциями; заголовок — в каждой")
    func chunked() throws {
        let device = try ChatDevice()
        let chat = try device.chats.createChat(title: "Длинный", at: date)
        let body = String(repeating: "я", count: 100_000)
        for index in 0..<12 { try device.chats.append(body, id: UUID(), to: chat.id, at: date.addingTimeInterval(Double(index))) }

        var portions: [AIChatSyncRecord] = []
        while let pending = try AIChatSync.pending(in: device.notes, maxBytes: 500_000) {
            #expect(pending.records.count == 1)
            portions += pending.records
            try AIChatSync.didSend(pending, in: device.notes)
        }
        #expect(portions.count > 1)
        #expect(portions.allSatisfy { $0.id == chat.id && $0.title == "Длинный" })
        #expect(portions.flatMap(\.messages).count == 12)
    }

    @Test("Чат с другого устройства появляется целиком; повторная пачка ничего не дублирует и не шлётся обратно")
    func receiveNewChat() throws {
        let a = try ChatDevice()
        let b = try ChatDevice()
        let chat = try a.chats.createChat(title: "С Mac", at: date)
        try a.chats.append("вопрос", id: UUID(), to: chat.id, at: date)
        try a.chats.append("ответ", id: UUID(), to: chat.id, at: date.addingTimeInterval(1))
        let sent = try a.sendAll()

        #expect(try b.receive(sent))
        #expect(try !b.receive(sent), "Повтор — без изменений")
        #expect(try b.chats.chats().map(\.title) == ["С Mac"])
        #expect(try b.chats.messages(in: chat.id).map(\.body) == ["вопрос", "ответ"])
        #expect(try b.chats.chat(chat.id)?.updatedAt == date.addingTimeInterval(1))
        #expect(try b.pending() == nil, "Пришедшее не уходит обратно")
    }

    @Test("Два устройства переименовали чат без связи — побеждает поздняя метка, на обоих одинаково")
    func renameConverges() throws {
        let a = try ChatDevice(wallMillis: 10_000)
        let b = try ChatDevice(wallMillis: 10_000)
        let chat = try a.chats.createChat(title: "Чат", at: date)
        try b.receive(a.sendAll())

        b.setWall(90_000)
        try b.chats.rename(chat.id, to: "С B")
        a.setWall(60_000)
        try a.chats.rename(chat.id, to: "С A")
        let fromA = try a.sendAll()
        let fromB = try b.sendAll()
        try a.receive(fromB)
        try b.receive(fromA)
        #expect(try a.chats.chat(chat.id)?.title == "С B")
        #expect(try b.chats.chat(chat.id)?.title == "С B")
    }

    @Test("Сообщения двух устройств в одном чате складываются, ничего не пропадает")
    func messagesMerge() throws {
        let a = try ChatDevice()
        let b = try ChatDevice()
        let chat = try a.chats.createChat(title: "Общий", at: date)
        try b.receive(a.sendAll())
        try a.chats.append("с A", id: UUID(), to: chat.id, at: date.addingTimeInterval(1))
        try b.chats.append("с B", id: UUID(), to: chat.id, at: date.addingTimeInterval(2))
        try b.receive(a.sendAll())
        try a.receive(b.sendAll())
        #expect(Set(try a.chats.messages(in: chat.id).map(\.body)) == ["с A", "с B"])
        #expect(try a.chats.messages(in: chat.id).map(\.body) == b.chats.messages(in: chat.id).map(\.body), "Порядок одинаковый")
        #expect(try a.chats.chat(chat.id)?.updatedAt == date.addingTimeInterval(2))
    }

    @Test("Просьба прислать чаты: устройство отмечает к отправке все свои, без встречной просьбы")
    func answersRequest() throws {
        let a = try ChatDevice()
        let chat = try a.chats.createChat(title: "Старый", at: date)
        try a.chats.append("x", id: UUID(), to: chat.id, at: date)
        _ = try a.sendAll()

        try a.receive([], requestedByOthers: true)
        let pending = try #require(try a.pending())
        #expect(pending.request == nil)
        #expect(pending.records.first?.messages.map(\.body) == ["x"])
    }

    @Test("Своя просьба уходит пачкой и снимается после отправки")
    func ownRequest() throws {
        let a = try ChatDevice()
        try a.notes.database.dbWriter.write { try AIChatSync.markAllForSending(requestingOthers: true, in: $0) }
        let pending = try #require(try a.pending())
        #expect(pending.request != nil)
        #expect(pending.records.isEmpty)
        try AIChatSync.didSend(pending, in: a.notes)
        #expect(try a.pending() == nil)
    }

    @Test("Снимок: все чаты с сообщениями; новое устройство восстанавливает их из снимка")
    func snapshot() throws {
        let a = try ChatDevice()
        let chat = try a.chats.createChat(title: "Из снимка", at: date)
        try a.chats.append("m", id: UUID(), to: chat.id, at: date)
        let all = try a.notes.database.dbWriter.read { try AIChatSync.all(in: $0) }
        #expect(all.count == 1)
        #expect(all.first?.messages.count == 1)

        let c = try ChatDevice()
        try c.receive(all)
        #expect(try c.chats.messages(in: chat.id).map(\.body) == ["m"])
    }

    @Test("Запись пачки читается и без новых полей; незнакомые поля пропускаются")
    func recordCoding() throws {
        let record = AIChatSyncRecord(id: UUID(), title: "Т", createdAt: date, updatedAt: date, deletedAt: nil,
                                      clock: HybridTimestamp(wallMillis: 5, counter: 1, deviceId: UUID()),
                                      messages: [.init(id: UUID(), position: 0, createdAt: date, body: "b")])
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(AIChatSyncRecord.self, from: data) == record)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["future"] = ["x": 1]
        let extended = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(AIChatSyncRecord.self, from: extended) == record)
    }
}
