/// Дробный ключ порядка среди соседей: между любыми двумя ключами есть ещё один,
/// поэтому вставка не перенумеровывает соседей. Цифры base-62 (`0-9A-Za-z`) идут
/// в порядке ASCII, так что порядок ключей совпадает с побайтовым порядком строк в SQLite.
/// Ключ не пуст и не кончается на `0` — иначе перед ним не нашлось бы места.
public struct FractionalSortKey: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.last != "0",
              rawValue.utf8.allSatisfy({ Self.digitValue[Int($0)] >= 0 })
        else { return nil }
        self.rawValue = rawValue
    }

    private init(digits: [Int]) {
        rawValue = String(decoding: digits.map { Self.alphabet[$0] }, as: UTF8.self)
    }

    public var description: String { rawValue }

    /// Ключ — только цифры ASCII, поэтому сравнение строк Swift совпадает с побайтовым и идёт быстрым путём для ASCII:
    /// документ сортирует 1 000 блоков на каждом открытии страницы (research R15).
    public static func < (lhs: FractionalSortKey, rhs: FractionalSortKey) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Ключ строго между `before` и `after`; `nil` — край списка.
    public static func between(_ before: FractionalSortKey?, _ after: FractionalSortKey?) -> FractionalSortKey {
        if let before, let after { precondition(before < after, "Ключи соседей идут не по порядку: \(before) ≥ \(after)") }
        let lower = before?.digits ?? []
        if let after {
            return FractionalSortKey(digits: midpoint(lower, after.digits))
        }
        return FractionalSortKey(digits: incremented(lower))
    }

    // MARK: Цифры

    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    private static let base = alphabet.count
    private static let digitValue: [Int] = {
        var table = [Int](repeating: -1, count: 256)
        for (value, byte) in alphabet.enumerated() { table[Int(byte)] = value }
        return table
    }()

    private var digits: [Int] { rawValue.utf8.map { Self.digitValue[Int($0)] } }

    /// Ключ в конец: увеличить первую цифру, которую можно увеличить. Набор страницы
    /// сверху вниз удлиняет ключ на символ лишь раз в ~60 блоков.
    private static func incremented(_ lower: [Int]) -> [Int] {
        guard !lower.isEmpty else { return [base / 2] }
        for position in lower.indices where lower[position] < base - 1 {
            return Array(lower[..<position]) + [lower[position] + 1]
        }
        return lower + [1]
    }

    /// Середина между `lower` (может быть пуст — «ноль») и `upper`.
    private static func midpoint(_ lower: [Int], _ upper: [Int]) -> [Int] {
        var common = 0
        while common < upper.count, (common < lower.count ? lower[common] : 0) == upper[common] {
            common += 1
        }
        if common > 0 {
            return Array(upper[..<common]) + midpoint(Array(lower.dropFirst(common)), Array(upper.dropFirst(common)))
        }
        let lowerDigit = lower.first ?? 0
        let upperDigit = upper[0]
        if upperDigit - lowerDigit > 1 {
            return [(lowerDigit + upperDigit + 1) / 2]
        }
        if upper.count > 1 {
            return [upperDigit]
        }
        return [lowerDigit] + midpointAbove(Array(lower.dropFirst()))
    }

    /// Середина между `lower` и «единицей» следующего разряда. Цикл, а не рекурсия:
    /// у ключа, подошедшего снизу к соседу, длинный хвост из `z`.
    private static func midpointAbove(_ lower: [Int]) -> [Int] {
        var result: [Int] = []
        for position in 0... {
            let lowerDigit = position < lower.count ? lower[position] : 0
            if base - lowerDigit > 1 {
                result.append((lowerDigit + base + 1) / 2)
                return result
            }
            result.append(lowerDigit)
        }
        fatalError("недостижимо")
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let key = FractionalSortKey(rawValue: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Не ключ порядка: \(text)")
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
