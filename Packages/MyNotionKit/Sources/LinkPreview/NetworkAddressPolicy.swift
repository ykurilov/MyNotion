import Darwin
import Foundation

/// Куда карточкам, обложкам и картинкам сайтов ходить нельзя: этот Mac и локальная сеть (роутер, NAS, принтер,
/// служебные адреса облака). Иначе страница сайта через `og:image` или переадресацию дёргала бы их от имени Юрия.
public struct NetworkAddressPolicy: Sendable {
    /// Адреса имени; пусто — имя не нашлось, запрос не пройдёт и сам.
    let resolve: @Sendable (String) -> [String]

    public init(resolve: @escaping @Sendable (String) -> [String]) {
        self.resolve = resolve
    }

    /// Имена — через DNS системы.
    public static let system = NetworkAddressPolicy(resolve: resolveWithSystem)

    /// Адрес в интернете: имя и все его адреса — не этого Mac и не локальной сети.
    public func allows(_ url: URL) -> Bool {
        guard var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return false }
        let addresses = IPAddress(host).map { [$0] } ?? resolve(host).compactMap(IPAddress.init)
        return addresses.allSatisfy(\.isPublic)
    }

    private static func resolveWithSystem(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var result: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: buffer))
            }
        }
        return result
    }
}

/// IPv4 или IPv6 адрес байтами.
struct IPAddress {
    let bytes: [UInt8]

    init?(_ text: String) {
        let text = text.split(separator: "%").first.map(String.init) ?? text
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            bytes = withUnsafeBytes(of: v4) { Array($0) }
        } else if inet_pton(AF_INET6, text, &v6) == 1 {
            bytes = withUnsafeBytes(of: v6) { Array($0) }
        } else {
            return nil
        }
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isPublic: Bool {
        bytes.count == 4 ? Self.isPublicV4(bytes) : isPublicV6
    }

    private static func isPublicV4(_ b: [UInt8]) -> Bool {
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _): false
        case (100, 64...127): false
        case (169, 254): false
        case (172, 16...31): false
        case (192, 168): false
        case (192, 0) where b[2] == 0: false
        case (198, 18...19): false
        case (224..., _): false
        default: true
        }
    }

    private var isPublicV6: Bool {
        if bytes[0..<10].allSatisfy({ $0 == 0 }) {
            // ::, ::1, IPv4 внутри IPv6 (::ffff:a.b.c.d и старое ::a.b.c.d).
            let tail = Array(bytes[12..<16])
            if bytes[10] == 0xFF, bytes[11] == 0xFF { return Self.isPublicV4(tail) }
            if bytes[10] == 0, bytes[11] == 0 { return tail.allSatisfy { $0 == 0 } || tail == [0, 0, 0, 1] ? false : Self.isPublicV4(tail) }
        }
        if bytes[0] & 0xFE == 0xFC { return false }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return false }
        if bytes[0] == 0xFF { return false }
        return true
    }
}
