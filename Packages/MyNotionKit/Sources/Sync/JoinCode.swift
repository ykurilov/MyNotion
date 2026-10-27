import CryptoKit
import Foundation

/// Код подключения второго Mac (research R9): одноразовое приглашение сервера и ключ шифрования записей.
/// Вводится руками: буквы и цифры без путаницы 0/O и 1/I, группы по четыре, в конце — контроль опечаток.
public struct JoinCode: Sendable {
    public let inviteCode: String
    public let encryptionKey: SymmetricKey

    /// Предупреждение рядом с кодом (T080).
    public static let warning = "Код открывает все записи. Не пересылайте его в мессенджерах — введите вручную"

    public init(inviteCode: String, encryptionKey: SymmetricKey) {
        self.inviteCode = inviteCode.uppercased()
        self.encryptionKey = encryptionKey
    }

    /// `XXXX-XXXX-…`: приглашение, ключ и 4 знака контроля.
    public var text: String {
        let key = encryptionKey.withUnsafeBytes { Data($0) }
        let body = inviteCode + Crockford.encode(key) + Self.check(invite: inviteCode, key: key)
        return stride(from: 0, to: body.count, by: 4).map { start in
            let from = body.index(body.startIndex, offsetBy: start)
            let to = body.index(from, offsetBy: min(4, body.count - start))
            return String(body[from..<to])
        }.joined(separator: "-")
    }

    public init(parsing typed: String) throws {
        let body = Crockford.normalized(typed)
        let keyLength = Crockford.encodedLength(byteCount: 32)
        guard body.count > keyLength + 4 else { throw JoinCodeError.mistyped }
        let invite = String(body.prefix(body.count - keyLength - 4))
        let keyText = String(body.dropFirst(invite.count).prefix(keyLength))
        let check = String(body.suffix(4))
        guard let key = Crockford.decode(keyText, byteCount: 32), Self.check(invite: invite, key: key) == check else {
            throw JoinCodeError.mistyped
        }
        self.init(inviteCode: invite, encryptionKey: SymmetricKey(data: key))
    }

    private static func check(invite: String, key: Data) -> String {
        let digest = Data(SHA256.hash(data: Data(invite.utf8) + key))
        return String(Crockford.encode(digest.prefix(3)).prefix(4))
    }
}

extension JoinCode {
    /// Сколько ещё действует код — минутами, а не временем суток («до 0:10» читалось как полночь).
    public static func lifetimeText(until expiresAt: Date, now: Date = Date()) -> String {
        let seconds = expiresAt.timeIntervalSince(now)
        guard seconds > 0 else { return "Код больше не действует — нажмите «Добавить Mac или iPhone» ещё раз" }
        let minutes = Int((seconds / 60).rounded(.up))
        return "Код одноразовый и действует ещё \(minutes) \(minuteWord(minutes))"
    }

    private static func minuteWord(_ count: Int) -> String {
        let lastTwo = count % 100, last = count % 10
        if (11...14).contains(lastTwo) { return "минут" }
        switch last {
        case 1: return "минуту"
        case 2...4: return "минуты"
        default: return "минут"
        }
    }
}

/// Ключ первого Mac — файл, который выдают при установке MyNotion (`MYNOTION_SYNC_URL=…`, `MYNOTION_SYNC_DEVICE_TOKEN=…`)
/// или файл с одним ключом в строке. Адрес из файла заменяет адрес по умолчанию.
public struct FirstMacKey: Sendable, Equatable {
    public var serverURL: URL?
    public var secret: String

    public init?(fileText: String) {
        var values: [String: String] = [:]
        let lines = fileText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for line in lines {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        if let secret = values["MYNOTION_SYNC_DEVICE_TOKEN"], !secret.isEmpty {
            self.secret = secret
            serverURL = values["MYNOTION_SYNC_URL"].flatMap(URL.init(string:))
        } else if values.isEmpty, lines.count == 1 {
            secret = lines[0]
            serverURL = nil
        } else {
            return nil
        }
    }
}

public enum JoinCodeError: Error, Equatable, LocalizedError {
    case mistyped

    public var errorDescription: String? { "В коде опечатка — сверьте его с экраном другого Mac" }
}

/// Base32 Дугласа Крокфорда: 0–9 и буквы без I, L, O, U.
enum Crockford {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func encodedLength(byteCount: Int) -> Int { (byteCount * 8 + 4) / 5 }

    static func encode(_ data: Data) -> String {
        var result = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(alphabet[(buffer >> bits) & 31])
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { result.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return result
    }

    static func decode(_ text: String, byteCount: Int) -> Data? {
        var data = Data()
        var buffer = 0
        var bits = 0
        for character in text {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                data.append(UInt8((buffer >> bits) & 0xFF))
                buffer &= (1 << bits) - 1
            }
        }
        return data.count == byteCount ? data : nil
    }

    /// Верхний регистр, без пробелов и дефисов; O читается как 0, I и L — как 1.
    static func normalized(_ text: String) -> String {
        String(text.uppercased().compactMap { character -> Character? in
            switch character {
            case " ", "-", "\n", "\t": nil
            case "O": "0"
            case "I", "L": "1"
            default: character
            }
        })
    }
}
