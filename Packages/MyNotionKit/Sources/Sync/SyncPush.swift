import Foundation

/// Среда токена тихих пушей Apple: отладочная сборка из Xcode — `sandbox`, TestFlight и App Store — `production`.
public enum SyncPushEnvironment: String, Sendable, Hashable, Codable {
    case sandbox
    case production
}

/// Тихие пуши (specs/007-iphone-app, этап 1П): iPhone сообщает серверу свой токен APNs, и сервер будит его,
/// когда с другого устройства пришла пачка. Пачки iPhone забирает сам — в пуше ничего из записей нет.
public protocol SyncPushTransport: Sendable {
    /// Токен устройства (`PUT /devices/me/push-token`); повтор безопасен, новый токен заменяет старый.
    func registerPushToken(_ token: Data, environment: SyncPushEnvironment) async throws
}

extension HTTPSyncServer {
    public func pushTransport(deviceToken: String) -> any SyncPushTransport {
        HTTPSyncTransport(baseURL: url, token: deviceToken, session: session)
    }
}

extension HTTPSyncTransport: SyncPushTransport {
    func registerPushToken(_ token: Data, environment: SyncPushEnvironment) async throws {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        let _: Ignored = try await send("PUT", "devices/me/push-token", body: ["token": hex, "environment": environment.rawValue])
    }
}
