import Foundation
import Testing
@testable import Sync

#if os(macOS)
/// Регистрация токена тихих пушей против настоящего сервера из server/. Сервер — процесс Node: только на Mac.
@Suite("Токен пушей на сервере")
struct SyncPushTransportTests {
    @Test("Устройство кладёт свой токен APNs в hex; повтор и новый токен принимаются; чужой токен устройства — нет",
          .enabled(if: LocalNodeSyncServer.isAvailable))
    func httpClientRegistersPushToken() async throws {
        let server = try await LocalNodeSyncServer.start()
        defer { server.stop() }
        let token = try await server.bootstrapToken(name: "iPhone")
        let push = HTTPSyncServer(url: server.serverURL).pushTransport(deviceToken: token)
        let apnsToken = Data((0..<32).map { UInt8($0) })

        try await push.registerPushToken(apnsToken, environment: .sandbox)
        try await push.registerPushToken(apnsToken, environment: .sandbox)
        try await push.registerPushToken(Data(repeating: 0xAB, count: 32), environment: .production)

        await #expect(throws: SyncServerError.unauthorized) {
            try await HTTPSyncServer(url: server.serverURL).pushTransport(deviceToken: "not-a-device-token").registerPushToken(apnsToken, environment: .sandbox)
        }
    }
}
#endif
