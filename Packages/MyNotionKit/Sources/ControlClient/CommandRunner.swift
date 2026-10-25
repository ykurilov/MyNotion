import ControlProtocol
import Foundation

/// Доставка запроса приложению (R8): подключиться; нет сокета — запустить приложение в фоне и ждать его сокет.
public struct CommandRunner: Sendable {
    static let retryInterval = Duration.milliseconds(100)

    let launcher: any AppLaunching

    public init(launcher: any AppLaunching = SystemAppLauncher()) {
        self.launcher = launcher
    }

    public func run(_ request: ControlRequest, settings: ClientSettings,
                    onProgress: (ControlProgress) -> Void = { _ in }) -> ControlResponse {
        let path = settings.socketPath ?? ControlSocketPath.standard
        if let fd = SocketClient.connect(path) {
            return SocketClient.exchange(fd, request, onProgress: onProgress)
        }

        // Приложение уже идёт, но сокета нет: оно ещё открывает базу или ждёт окна восстановления — только ждать.
        let wasRunning = launcher.isAppRunning()
        if !wasRunning {
            guard !settings.noLaunch else {
                return .failure(request.id, ControlError(.appNotRunning, "MyNotion не запущен",
                                                         hint: "Запустите приложение или уберите --no-launch",
                                                         details: ["socket": .string(path)]))
            }
            do {
                try launcher.launch()
            } catch {
                return notReady(request, path, reason: "launch_failed", message: "Не удалось запустить MyNotion: \(error.localizedDescription)")
            }
        }

        let deadline = ContinuousClock.now + .milliseconds(Int64(settings.launchTimeout * 1_000))
        while ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: min(0.1, max(0, Self.seconds(deadline - ContinuousClock.now))))
            if let fd = SocketClient.connect(path) {
                return SocketClient.exchange(fd, request, onProgress: onProgress)
            }
        }
        return wasRunning
            ? notReady(request, path, reason: "socket_missing",
                       message: "MyNotion запущен, но не принимает команды: нет сокета \(path)")
            : notReady(request, path, reason: "launch_timeout",
                       message: "MyNotion не открылся за \(Self.secondsText(settings.launchTimeout)) с")
    }

    private func notReady(_ request: ControlRequest, _ path: String, reason: String, message: String) -> ControlResponse {
        .failure(request.id, ControlError(.appNotReady, message,
                                          hint: "Если открыто окно восстановления — закройте его; дольше ждать: --launch-timeout <с>",
                                          details: ["reason": .string(reason), "socket": .string(path)]))
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    private static func secondsText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
