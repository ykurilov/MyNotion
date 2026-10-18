import Foundation

/// Живая проверка синхронизации двумя экземплярами в виртуальном Mac (quickstart.md): подключение по флагам
/// запуска вместо окна настроек. Токен читается из файла и файл стирается; код подключения пишется в файл.
@MainActor
enum SyncAutomation {
    struct Options {
        var serverAddress: String?
        var deviceName: String?
        /// Первый Mac: файл с токеном устройства.
        var tokenFile: URL?
        /// Первый Mac: куда записать код подключения для второго.
        var joinCodeOutput: URL?
        /// Второй Mac: файл с кодом (ждём, пока появится).
        var joinCodeInput: URL?

        func with(_ change: (inout Options) -> Void) -> Options {
            var copy = self
            change(&copy)
            return copy
        }
    }

    static func start(_ options: Options, controller: SyncController) {
        if let address = options.serverAddress { controller.serverAddress = address }
        if let name = options.deviceName { controller.deviceName = name }
        Task {
            if !controller.isEnabled, let tokenFile = options.tokenFile,
               let token = try? String(contentsOf: tokenFile, encoding: .utf8) {
                try? FileManager.default.removeItem(at: tokenFile)
                await controller.connectFirstDevice(token: token)
            }
            if !controller.isEnabled, let codeFile = options.joinCodeInput {
                while !FileManager.default.fileExists(atPath: codeFile.path) {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if let code = try? String(contentsOf: codeFile, encoding: .utf8) { await controller.join(codeText: code) }
            }
            if controller.isEnabled, let output = options.joinCodeOutput {
                await controller.makeJoinCode()
                try? controller.joinCode?.text.write(to: output, atomically: true, encoding: .utf8)
            }
            if let error = controller.errorMessage {
                FileHandle.standardError.write(Data("Синхронизация: \(error)\n".utf8))
            }
        }
    }
}
