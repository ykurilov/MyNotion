import Foundation
import Testing
@testable import Sync

/// Тексты синхронизации — для человека не из IT (проверка интерфейса, раунд 4, № 2, 8, 9): в строках, которые видит
/// Юрий, нет слов разработчика. Проверяются строки с русскими буквами в файлах синхронизации; комментарии,
/// служебный журнал и метки для тестов не в счёт.
@Suite("Тексты синхронизации простыми словами")
struct UserFacingTextTests {
    static let jargon = ["токен", "сервер", "пачк", "журнал", "шифр", "устройств", "bootstrap", "синхронизация журнала",
                         "транзакц", "очеред", "id ", "HLC", "API"]

    static let files = [
        "App/Settings/SyncSettingsView.swift", "App/Settings/SyncController.swift", "App/Settings/SyncNoticeView.swift",
        "Packages/MyNotionKit/Sources/PageTree/SyncStatusBadge.swift",
        "Packages/MyNotionKit/Sources/PageEditor/ConflictResolutionView.swift",
        "Packages/MyNotionKit/Sources/Sync/SyncEngine.swift", "Packages/MyNotionKit/Sources/Sync/SyncClient.swift",
        "Packages/MyNotionKit/Sources/Sync/BatchCipher.swift", "Packages/MyNotionKit/Sources/Sync/SyncSetup.swift",
        "Packages/MyNotionKit/Sources/Sync/JoinCode.swift", "Packages/MyNotionKit/Sources/Sync/ChangeMerger.swift",
    ]

    static var repository: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    /// Проверка читает исходники: где их нет (виртуальный Mac, куда приходят только собранные тесты), её не запускаем.
    static var hasSources: Bool {
        FileManager.default.fileExists(atPath: repository.appendingPathComponent(files[0]).path)
    }

    /// Строки в кавычках с русскими буквами, кроме комментариев и служебных мест.
    static func userFacingStrings(in file: String) throws -> [String] {
        let text = try String(contentsOf: repository.appendingPathComponent(file), encoding: .utf8)
        let skipped = ["//", "log(", "standardError", "print(", "accessibilityIdentifier", "DecodingError", "precondition", "fatalError"]
        var result: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !skipped.contains(where: { trimmed.hasPrefix($0) || line.contains($0) && $0 != "//" }) else { continue }
            let code = line.components(separatedBy: " // ").first ?? String(line)
            for match in code.matches(of: /"((?:[^"\\]|\\.)*)"/) {
                let literal = String(match.1)
                if literal.contains(where: { ("а"..."я").contains($0) || ("А"..."Я").contains($0) || $0 == "ё" }) {
                    result.append(literal)
                }
            }
        }
        return result
    }

    @Test("В строках синхронизации нет слов разработчика", .enabled(if: hasSources, "нет исходников рядом с тестами"),
          arguments: files)
    func noJargon(_ file: String) throws {
        let strings = try Self.userFacingStrings(in: file)
        for string in strings {
            for word in Self.jargon where string.localizedCaseInsensitiveContains(word) {
                Issue.record("«\(word)» в «\(string)» (\(file))")
            }
        }
    }

    @Test("Проверка видит строки: в настройках они есть", .enabled(if: hasSources, "нет исходников рядом с тестами"))
    func scannerFindsStrings() throws {
        #expect(try Self.userFacingStrings(in: "App/Settings/SyncSettingsView.swift").count > 10)
    }

    @Test("Ошибки связи — простыми словами, без системного текста про серверы")
    func errorMessagesArePlain() {
        let errors: [any Error] = [URLError(.cannotFindHost), URLError(.notConnectedToInternet), URLError(.badServerResponse),
                                   SyncServerError.unauthorized, SyncServerError.tooLarge, SyncServerError.server("Ошибка на сервере"),
                                   BatchCipherError.tampered, SyncSetupError.missingSecrets]
        for error in errors {
            let message = SyncEngine.message(for: error)
            for word in Self.jargon { #expect(!message.localizedCaseInsensitiveContains(word), "«\(word)» в «\(message)»") }
        }
    }

    @Test("Срок кода: «действует ещё N минут», а не время суток (№ 8)")
    func joinCodeLifetime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(JoinCode.lifetimeText(until: now.addingTimeInterval(15 * 60), now: now) == "Код одноразовый и действует ещё 15 минут")
        #expect(JoinCode.lifetimeText(until: now.addingTimeInterval(61), now: now) == "Код одноразовый и действует ещё 2 минуты")
        #expect(JoinCode.lifetimeText(until: now.addingTimeInterval(21 * 60), now: now) == "Код одноразовый и действует ещё 21 минуту")
        #expect(JoinCode.lifetimeText(until: now.addingTimeInterval(-5), now: now) == "Код больше не действует — нажмите «Добавить Mac» ещё раз")
    }

    @Test("Ключ первого Mac читается из файла: адрес и ключ; простой файл с одним ключом тоже")
    func firstMacKeyFile() throws {
        let env = FirstMacKey(fileText: "MYNOTION_SYNC_URL=https://example.test\nMYNOTION_SYNC_DEVICE_TOKEN=abc123\n")
        #expect(env?.serverURL == URL(string: "https://example.test"))
        #expect(env?.secret == "abc123")
        #expect(FirstMacKey(fileText: "  xyz789\n")?.secret == "xyz789")
        #expect(FirstMacKey(fileText: "MYNOTION_SYNC_URL=https://x\n") == nil)
    }
}
