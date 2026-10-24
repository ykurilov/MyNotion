import Foundation

/// Опциональная синхронизация с внешним `sample` для первого удаления или возврата проекта.
/// Это диагностический прогон: длительность под профилировщиком не заменяет обычный бюджет.
struct ColdTrashProfile {
    enum Phase: String { case trash, restore }
    let folder: URL
    let phase: Phase

    static func requested() throws -> ColdTrashProfile? {
        guard let path = ProcessInfo.processInfo.environment["MYNOTION_RELATION_PROFILE_DIR"] else { return nil }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rawPhase = ProcessInfo.processInfo.environment["MYNOTION_RELATION_PROFILE_PHASE"] ?? "trash"
        guard let phase = Phase(rawValue: rawPhase) else { throw Failure.invalidPhase(rawPhase) }
        return ColdTrashProfile(folder: folder, phase: phase)
    }

    func beforeFirst(_ phase: Phase) throws {
        guard phase == self.phase else { return }
        try String(ProcessInfo.processInfo.processIdentifier).write(to: folder.appendingPathComponent("test.pid"), atomically: true, encoding: .utf8)
        try awaitFile("sample-ready")
    }

    func afterFirst(_ phase: Phase, milliseconds: Double) throws {
        guard phase == self.phase else { return }
        try String(milliseconds).write(to: folder.appendingPathComponent("first-\(phase.rawValue)-ms"), atomically: true, encoding: .utf8)
        try Data().write(to: folder.appendingPathComponent("first-\(phase.rawValue)-done"), options: .atomic)
        try awaitFile("sample-finished")
    }

    private func awaitFile(_ name: String) throws {
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            guard Date() < deadline else { throw Failure.timeout(name) }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private enum Failure: Error { case timeout(String), invalidPhase(String) }
}
