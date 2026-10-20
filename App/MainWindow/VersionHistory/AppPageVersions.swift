import Foundation
import NotesCore
import PageVersions

/// История версий приложения (research R11): отметки в транзакциях записи — с первой записи библиотеки; запись снимков
/// и прореживание — только после готовности редактора; при закрытии окна и выходе — снимки всего отмеченного.
@MainActor
final class AppPageVersions {
    let versions: PageVersionStore
    let recorder: PageVersionRecorder
    private let pruner: VersionPruner
    private var pruneTimer: Timer?
    /// Прореживание идёт раз в сутки; проверка «пора ли» — раз в час, на общей очереди.
    private static let pruneCheckInterval: TimeInterval = 3_600

    init(store: NotesStore, deviceName: String, timing: PageVersionRecorder.Timing = .standard) {
        versions = PageVersionStore(store: store)
        recorder = PageVersionRecorder(store: store, versions: versions, timing: timing)
        recorder.installDueMarker(localDeviceName: deviceName)
        pruner = VersionPruner(versions: versions, store: store)
    }

    /// Редактор первого окна готов к вводу.
    func editorReady() {
        guard pruneTimer == nil else { return }
        recorder.start()
        prune()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: Self.pruneCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
    }

    func pageOpened(_ pageId: UUID) {
        recorder.pageOpened(pageId)
    }

    /// Закрытие окна и выход: открытые страницы уже записаны.
    func recordAllDue() {
        recorder.recordAllDue()
    }

    private func prune() {
        let pruner = pruner
        DispatchQueue.global(qos: .utility).async { _ = try? pruner.pruneIfDue() }
    }
}
