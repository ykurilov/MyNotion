import AppKit
import NotesCore
import NotionImport
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VisualStyle

/// «Файл → Импорт из Notion…» (FR-025…FR-027, T090).
struct NotionImportCommands: Commands {
    let controller: NotionImportController?

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Импорт из Notion…") { controller?.chooseSourceAndImport() }
                .disabled(controller == nil || controller?.isBusy == true)
        }
    }
}

/// Импорт в фоне: окно не замирает, ход виден в карточке внизу, в конце — окно отчёта.
/// Повтор той же выгрузки (по отпечатку содержимого) спрашивается до начала.
@MainActor
@Observable
final class NotionImportController {
    enum State: Equatable {
        case idle
        /// Распаковка и отпечаток: сколько страниц, ещё не известно.
        case preparing
        /// Эту выгрузку уже импортировали: импортировать ли ещё раз.
        case confirmRepeat(previous: NotionImportRun)
        case running(NotionImportProgress)
        case finished(NotionImportReport)
        case failed(String)
    }

    private(set) var state = State.idle
    @ObservationIgnored private let store: NotesStore
    /// Записать правки открытых страниц: импорт пишет в ту же базу. `false` — не записалось.
    @ObservationIgnored private let saveOpenPages: @MainActor () -> Bool
    /// Ветка импорта появилась: перечитать дерево и открыть её.
    @ObservationIgnored private let showBranch: @MainActor (UUID) -> Void
    @ObservationIgnored private var prepared: PreparedNotionExport?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: NotesStore, saveOpenPages: @escaping @MainActor () -> Bool, showBranch: @escaping @MainActor (UUID) -> Void) {
        self.store = store
        self.saveOpenPages = saveOpenPages
        self.showBranch = showBranch
    }

    var isBusy: Bool {
        switch state {
        case .preparing, .running, .confirmRepeat: true
        default: false
        }
    }

    func chooseSourceAndImport() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder]
        panel.prompt = "Импортировать"
        panel.message = "Выберите ZIP выгрузки Notion («Export → Markdown & CSV») или папку с распакованной выгрузкой"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let source = panel.url else { return }
        start(source)
    }

    /// Распаковать и посчитать отпечаток; был такой импорт — спросить, не было — сразу импортировать.
    func start(_ source: URL) {
        guard !isBusy else { return }
        state = .preparing
        let store = store
        task = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(PreparedNotionExport, NotionImportRun?), any Error> in
                Result {
                    let prepared = try NotionExportUnpacker().prepare(source)
                    do {
                        return (prepared, try NotionImporter(store: store).previousImport(withFingerprint: prepared.fingerprint))
                    } catch {
                        prepared.discard()
                        throw error
                    }
                }
            }.value
            self?.didPrepare(outcome)
        }
    }

    private func didPrepare(_ outcome: Result<(PreparedNotionExport, NotionImportRun?), any Error>) {
        switch outcome {
        case .failure(let error):
            state = .failed(Self.message(for: error))
        case .success(let (prepared, previous)):
            self.prepared = prepared
            if let previous {
                state = .confirmRepeat(previous: previous)
            } else {
                runImport()
            }
        }
    }

    func confirmRepeat() {
        guard case .confirmRepeat = state else { return }
        runImport()
    }

    func cancelRepeat() {
        guard case .confirmRepeat = state else { return }
        prepared?.discard()
        prepared = nil
        state = .idle
    }

    private func runImport() {
        guard let prepared else { return }
        guard saveOpenPages() else {
            finish(.failure(NotionImportError.cannotWrite("правки открытой страницы не записались на диск, импорт не начат")))
            return
        }
        state = .running(NotionImportProgress(phase: .reading, done: 0, total: 0))
        let importer = NotionImporter(store: store)
        task = Task { [weak self] in
            let detached = Task.detached(priority: .userInitiated) { () -> Result<NotionImportReport, any Error> in
                Result {
                    try importer.importExport(prepared) { step in
                        Task { @MainActor in self?.report(step) }
                    }
                }
            }
            // «Остановить» отменяет эту задачу, а с ней — импорт в фоне.
            let outcome = await withTaskCancellationHandler { await detached.value } onCancel: { detached.cancel() }
            prepared.discard()
            self?.prepared = nil
            self?.finish(outcome)
        }
    }

    /// Остановить импорт: ветка откатывается целиком.
    func stop() {
        guard case .running = state else { return }
        task?.cancel()
    }

    func dismiss() {
        guard !isBusy else { return }
        state = .idle
    }

    func openBranch(_ report: NotionImportReport) {
        state = .idle
        showBranch(report.rootPageId)
    }

    private func report(_ step: NotionImportProgress) {
        guard case .running = state else { return }
        state = .running(step)
    }

    private func finish(_ outcome: Result<NotionImportReport, any Error>) {
        switch outcome {
        case .success(let report):
            state = .finished(report)
            showBranch(report.rootPageId)
        case .failure(let error):
            state = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: any Error) -> String {
        error is CancellationError ? "Импорт остановлен. Недоделанная ветка убрана, прежние записи не тронуты."
            : error.localizedDescription
    }

    /// Состояние для галереи интерфейса, без настоящего импорта.
    func showPreview(_ preview: State) {
        state = preview
    }
}

/// Карточка внизу окна: ход импорта с кнопкой «Остановить» или понятная ошибка.
struct NotionImportNoticeView: View {
    let controller: NotionImportController

    var body: some View {
        if let content = noticeContent {
            HStack(spacing: 12) { content }
                .font(.system(size: 14))
                .foregroundStyle(Color(nsColor: Palette.textPrimary))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: 560)
                .background(Color(nsColor: Palette.popupMenuBackground), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: Palette.border)))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .padding(.bottom, 20)
                .transition(.opacity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("notion-import-notice")
        }
    }

    private var noticeContent: AnyView? {
        switch controller.state {
        case .preparing:
            AnyView(Group {
                ProgressView().controlSize(.small)
                Text("Импорт из Notion: распаковываю выгрузку…")
            })
        case .running(let step):
            AnyView(Group {
                if step.total > 0 {
                    ProgressView(value: Double(step.done), total: Double(step.total)).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(Self.progressText(step)).monospacedDigit()
                Button("Остановить") { controller.stop() }
                    .accessibilityIdentifier("notion-import-stop")
            })
        case .failed(let message):
            AnyView(Group {
                Text(message).foregroundStyle(Color(nsColor: Palette.destructiveText))
                Button("Закрыть") { controller.dismiss() }
                    .accessibilityIdentifier("notion-import-close")
            })
        case .idle, .confirmRepeat, .finished:
            nil
        }
    }

    static func progressText(_ step: NotionImportProgress) -> String {
        let action = step.phase == .reading ? "читаю страницы" : "записываю страницы"
        return step.total > 0 ? "Импорт из Notion: \(action) — \(step.done) из \(step.total)" : "Импорт из Notion: \(action)…"
    }
}

/// Окна поверх страницы: «уже импортировано — ещё раз?» и отчёт после импорта.
struct NotionImportSheets: ViewModifier {
    let controller: NotionImportController?

    func body(content: Content) -> some View {
        content.sheet(isPresented: isPresented) {
            if let controller {
                switch controller.state {
                case .confirmRepeat(let previous): NotionImportRepeatView(controller: controller, previous: previous)
                case .finished(let report): NotionImportReportView(controller: controller, report: report)
                default: EmptyView()
                }
            }
        }
    }

    private var isPresented: Binding<Bool> {
        Binding {
            switch controller?.state {
            case .confirmRepeat?, .finished?: true
            default: false
            }
        } set: { shown in
            guard !shown, let controller else { return }
            if case .confirmRepeat = controller.state { controller.cancelRepeat() } else { controller.dismiss() }
        }
    }
}

/// Отчёт (FR-026): сколько перенесено, где лежит, что упрощено до простого текста.
struct NotionImportReportView: View {
    let controller: NotionImportController
    let report: NotionImportReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Импорт из Notion завершён")
                .font(.system(size: 16, weight: .semibold))
            Text("Перенесено страниц: \(report.pageCount), блоков: \(report.blockCount). Всё лежит в ветке «\(report.rootTitle)».")
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("notion-import-summary")
            if report.simplified.isEmpty {
                Text("Всё перенесено как есть.")
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
            } else {
                Text("Упрощено до простого текста:")
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(report.simplified.enumerated()), id: \.offset) { _, page in
                            (Text(page.pageTitle).fontWeight(.medium) + Text(" — " + page.items.joined(separator: ", ")))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 220)
                .background(Color(nsColor: Palette.pageBackground), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: Palette.border)))
                .accessibilityIdentifier("notion-import-simplified")
            }
            HStack {
                Spacer()
                Button("Открыть ветку") { controller.openBranch(report) }
                    .accessibilityIdentifier("notion-import-open-branch")
                Button("Готово") { controller.dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("notion-import-done")
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(Color(nsColor: Palette.textPrimary))
        .padding(20)
        .frame(width: 480)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notion-import-report")
    }
}

/// Повтор той же выгрузки (FR-027): дубли молча не создаются.
struct NotionImportRepeatView: View {
    let controller: NotionImportController
    let previous: NotionImportRun

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Эта выгрузка уже импортирована")
                .font(.system(size: 16, weight: .semibold))
            Text("\(Self.dateText(previous.startedAt)) перенесено страниц: \(previous.importedPages). Если импортировать ещё раз, рядом появится вторая копия этих страниц.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Отмена") { controller.cancelRepeat() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("notion-import-cancel-repeat")
                Button("Импортировать ещё раз") { controller.confirmRepeat() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("notion-import-again")
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(Color(nsColor: Palette.textPrimary))
        .padding(20)
        .frame(width: 440)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notion-import-repeat")
    }

    /// «18 октября 2026 в 15:00».
    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy 'в' HH:mm"
        return formatter.string(from: date)
    }
}
