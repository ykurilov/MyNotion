import ControlProtocol

/// Код выхода по группе ошибки (contracts/protocol.md): 0 — успех.
public enum ExitCode {
    public static func of(_ response: ControlResponse) -> Int32 {
        guard !response.ok else { return 0 }
        return response.error?.code.group.exitCode ?? ControlErrorGroup.internalFailure.exitCode
    }
}
