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
        /// Куда писать ход синхронизации; без него — в стандартный поток ошибок.
        var logFile: URL?

        func with(_ change: (inout Options) -> Void) -> Options {
            var copy = self
            change(&copy)
            return copy
        }
    }

    static func start(_ options: Options, controller: SyncController) {
        func log(_ line: String) {
            let data = Data((line + "\n").utf8)
            guard let file = options.logFile else { return FileHandle.standardError.write(data) }
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: file)
            }
        }
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
                log("Синхронизация: \(error)")
            }
            // Ход проверки — в журнал: смена состояния значка с подробностями.
            var last: String?
            while true {
                let state = controller.badge.map { "\($0.title): \($0.detail)" } ?? "выключена"
                if state != last {
                    log("Синхронизация [\(Date().formatted(date: .omitted, time: .standard))] \(state)")
                    last = state
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}
