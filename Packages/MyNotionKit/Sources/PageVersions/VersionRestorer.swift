import Foundation
import NotesCore

/// «Восстановить эту версию» (research R11): снимок текущего вида, затем одна правка страницы под версию
/// (`PageTreeOperations.restoreVersion`, с отменой), затем новая версия — так в истории видно и «до», и «после».
@MainActor
public struct VersionRestorer {
    public let recorder: PageVersionRecorder
    public let versions: PageVersionStore
    public let operations: PageTreeOperations

    public init(recorder: PageVersionRecorder, versions: PageVersionStore, operations: PageTreeOperations) {
        self.recorder = recorder
        self.versions = versions
        self.operations = operations
    }

    public func restore(versionId: UUID, ofPage pageId: UUID) throws {
        guard let snapshot = try versions.snapshot(versionId) else { throw VersionRestoreError.versionGone }
        try recorder.recordPending(pageId)
        try operations.restoreVersion(of: pageId, to: snapshot.restoreTarget(pageId: pageId))
        try recorder.recordPending(pageId)
    }
}

public enum VersionRestoreError: Error, LocalizedError {
    case versionGone

    public var errorDescription: String? {
        switch self {
        case .versionGone: "Этой версии уже нет: её убрало прореживание истории"
        }
    }
}
