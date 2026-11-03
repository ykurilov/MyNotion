import Foundation
import NotesCore
import Synchronization

/// Откладывает проверку записывателя версий. В приложении — таймер вне главного потока, в тестах — часы теста.
public protocol VersionRecordingScheduler: Sendable {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void)
}

/// Таймер на общей очереди: проверка не трогает главный поток.
public struct BackgroundVersionScheduler: VersionRecordingScheduler {
    public init() {}

    public func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(delay, 0), execute: work)
    }
}

/// Записыватель версий (research R11): по отметкам `page_version_due`, без опроса. Снимок — когда у страницы прошла минута
/// с прошлой версии и 5 с без правок; пишется на своей очереди, вне главного потока. Ничего не пишет до `start()`
/// (готовность редактора). Закрытие окна — `recordAllDue()`, выход — `recordAllDueBeforeQuit()`; первое открытие страницы
/// без версий — снимок «как было». Главный поток очередь не ждёт — только при выходе.
public final class PageVersionRecorder: Sendable {
    /// Сроки записи: не чаще раза в `minimumInterval` на страницу и после `quietPeriod` без правок.
    public struct Timing: Sendable {
        public var minimumInterval: TimeInterval
        public var quietPeriod: TimeInterval

        public init(minimumInterval: TimeInterval, quietPeriod: TimeInterval) {
            self.minimumInterval = minimumInterval
            self.quietPeriod = quietPeriod
        }

        /// Минута и 5 секунд (research R11).
        public static let standard = Timing(minimumInterval: 60, quietPeriod: 5)
    }

    public let store: NotesStore
    public let timing: Timing
    public let versions: PageVersionStore
    let now: @Sendable () -> Date
    let scheduler: any VersionRecordingScheduler
    private let queue = DispatchQueue(label: "MyNotion.PageVersionRecorder", qos: .utility)
    private let state = Mutex(State())
    private let recordedHandler = Mutex<(@Sendable (PageVersionInfo) -> Void)?>(nil)

    private struct State {
        var isStarted = false
        /// Открытые до готовности редактора страницы: первая версия — после `start()`.
        var openedBeforeStart: [UUID] = []
        /// Срок уже поставленной проверки.
        var scheduledCheck: Date?
        /// Имя этого Mac: автор первой версии страницы, которую ещё никто не правил.
        var localDeviceName = "Этот Mac"
    }

    public init(store: NotesStore, versions: PageVersionStore, timing: Timing = .standard, now: @escaping @Sendable () -> Date = Date.init,
                scheduler: any VersionRecordingScheduler = BackgroundVersionScheduler()) {
        self.store = store
        self.timing = timing
        self.versions = versions
        self.now = now
        self.scheduler = scheduler
    }

    /// Записана версия (на очереди записывателя): для окна истории и замеров. Главный поток из него синхронно не ждать:
    /// при выходе он сам ждёт очередь (`recordAllDueBeforeQuit`).
    public var onRecorded: (@Sendable (PageVersionInfo) -> Void)? {
        get { recordedHandler.withLock { $0 } }
        set { recordedHandler.withLock { $0 = newValue } }
    }

    /// Подписать отметки на записи хранилища — до первой записи.
    public func installDueMarker(localDeviceName: String) {
        state.withLock { $0.localDeviceName = localDeviceName }
        store.addWriteHook(PageVersionDueMarker(localDeviceName: localDeviceName, now: now) { [weak self] in self?.dueMarked() })
    }

    /// Редактор готов: снимки отмеченного и первые версии открытых раньше страниц.
    public func start() {
        let opened = state.withLock { state -> [UUID] in
            guard !state.isStarted else { return [] }
            state.isStarted = true
            defer { state.openedBeforeStart = [] }
            return state.openedBeforeStart
        }
        for pageId in opened { pageOpened(pageId) }
        scheduleCheck(after: 0)
    }

    var isStarted: Bool { state.withLock { $0.isStarted } }

    /// Подписчик отметил страницы: проверить, кому пора.
    func dueMarked() {
        guard isStarted else { return }
        scheduleCheck(after: 0)
    }

    /// Страница открыта: у страницы без версий — снимок «как было», чтобы прошлое до первой правки не потерялось.
    public func pageOpened(_ pageId: UUID) {
        let started = state.withLock { state -> Bool in
            if !state.isStarted, !state.openedBeforeStart.contains(pageId) { state.openedBeforeStart.append(pageId) }
            return state.isStarted
        }
        guard started else { return }
        scheduler.schedule(after: 0) { [weak self] in
            guard let self else { return }
            queue.sync { _ = try? self.recordFirstVersionIfNeeded(pageId) }
        }
    }

    /// Закрытие окна: снимки всех отмеченных сейчас, без ожидания 5 с тишины — на очереди записывателя, окно её не ждёт.
    public func recordAllDue() async {
        guard isStarted else { return }
        await withCheckedContinuation { continuation in
            queue.async {
                self.recordDueNow()
                continuation.resume()
            }
        }
    }

    /// Выход: то же, но вызывающий ждёт — приложение закрывается после снимков.
    public func recordAllDueBeforeQuit() {
        guard isStarted else { return }
        queue.sync { recordDueNow() }
    }

    /// Снимок неснятых правок страницы сейчас (открытие истории, восстановление) — на очереди записывателя.
    /// `nil` — правок без версии нет.
    @discardableResult
    public func recordPending(_ pageId: UUID) async throws -> PageVersionInfo? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    if let mark = try self.versions.dueMark(ofPage: pageId) { return try self.record(pageId, deviceName: mark.deviceName) }
                    return try self.recordFirstVersionIfNeeded(pageId)
                })
            }
        }
    }

    /// Версия «до правки агента» (005) из снимка, снятого вызывающим прямо перед правкой, с именем агента в сводке —
    /// на очереди записывателя. Пишется уже после правки, поэтому отметку страницы не снимает: правка ждёт своей версии.
    @discardableResult
    public func recordAgentCheckpoint(_ content: PageContent, agent: String, deviceName: String?) async throws -> PageVersionInfo {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try self.record(content, deviceName: deviceName, agent: agent, clearsDueMark: false)
                })
            }
        }
    }

    // MARK: Очередь записывателя

    private func scheduleCheck(after delay: TimeInterval) {
        let deadline = now().addingTimeInterval(delay)
        let shouldSchedule = state.withLock { state -> Bool in
            if let scheduled = state.scheduledCheck, scheduled <= deadline { return false }
            state.scheduledCheck = deadline
            return true
        }
        guard shouldSchedule else { return }
        scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            queue.sync { self.checkDue() }
        }
    }

    private func recordDueNow() {
        for mark in (try? versions.duePages()) ?? [] { _ = try? record(mark.pageId, deviceName: mark.deviceName) }
    }

    /// Снять снимки страниц, которым пора; следующая проверка — к ближайшему сроку.
    private func checkDue() {
        state.withLock { $0.scheduledCheck = nil }
        let now = now()
        var nextDeadline: Date?
        for mark in (try? versions.duePages()) ?? [] {
            let lastVersionAt = (try? versions.versions(ofPage: mark.pageId).first?.createdAt) ?? nil
            var readyAt = mark.lastChangeAt.addingTimeInterval(timing.quietPeriod)
            if let lastVersionAt { readyAt = max(readyAt, lastVersionAt.addingTimeInterval(timing.minimumInterval)) }
            if readyAt <= now {
                _ = try? record(mark.pageId, deviceName: mark.deviceName)
            } else {
                nextDeadline = min(nextDeadline ?? readyAt, readyAt)
            }
        }
        if let nextDeadline { scheduleCheck(after: nextDeadline.timeIntervalSince(now)) }
    }

    @discardableResult
    private func recordFirstVersionIfNeeded(_ pageId: UUID) throws -> PageVersionInfo? {
        guard try versions.versions(ofPage: pageId).isEmpty else { return nil }
        return try record(pageId, deviceName: nil)
    }

    /// Снимок страницы из базы; сводка — разница с прошлой версией. Страницы нет — отметка снимается.
    @discardableResult
    private func record(_ pageId: UUID, deviceName: String?, agent: String? = nil) throws -> PageVersionInfo? {
        guard let read = try store.pageContentWithRowValues(pageId) else {
            try versions.clearDue(pageId: pageId, upTo: .distantFuture)
            return nil
        }
        return try record(read.content, rowValues: read.rowValues, deviceName: deviceName, agent: agent)
    }

    private func record(_ content: PageContent, rowValues: RowValues? = nil, deviceName: String?, agent: String? = nil,
                        clearsDueMark: Bool = true) throws -> PageVersionInfo {
        let createdAt = now()
        let pageId = content.page.id
        let snapshot = PageSnapshot(page: content.page, blocks: content.blocks, rowValues: rowValues)
        let previous = try versions.latest(ofPage: pageId)
        let author = deviceName ?? state.withLock { $0.localDeviceName }
        var summary = VersionDiff.summary(from: previous?.snapshot, to: snapshot)
        summary.agent = agent
        let info = try versions.save(snapshot, pageId: pageId, createdAt: createdAt, deviceName: author, summary: summary,
                                     clearsDueMark: clearsDueMark)
        onRecorded?(info)
        return info
    }
}
