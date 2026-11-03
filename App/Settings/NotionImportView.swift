import AppKit
import Attachments
import NotesCore
import NotionImport
import NotionSchemaFetch
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

/// Перенос в фоне: окно не замирает, ход виден в карточке внизу, в конце — окно итога.
/// Повтор того же файла из Notion (по отпечатку содержимого) спрашивается до начала.
@MainActor
@Observable
final class NotionImportController {
    enum State: Equatable {
        case idle
        /// Распаковка и отпечаток: сколько страниц, ещё не известно.
        case preparing
        /// Эту выгрузку уже импортировали: импортировать ли ещё раз.
        case confirmRepeat(previous: NotionImportRun)
        /// В выгрузке есть базы: предложить дочитать их схему из Notion (типы, цвета, формулы, сводки). `hasKey` — ключ уже сохранён.
        case offerSchema(databaseCount: Int, hasKey: Bool)
        /// Схемы баз читаются из Notion по ключу (только чтение).
        case fetchingSchema
        case running(NotionImportProgress)
        case finished(NotionImportReport)
        case failed(String)
    }

    private(set) var state = State.idle
    @ObservationIgnored private let store: NotesStore
    /// Картинки и файлы выгрузки копируются во вложения.
    @ObservationIgnored private let attachments: AttachmentStore?
    /// Записать правки открытых страниц: импорт пишет в ту же базу. `false` — не записалось.
    @ObservationIgnored private let saveOpenPages: @MainActor () -> Bool
    /// Ветка импорта появилась: перечитать дерево и открыть её.
    @ObservationIgnored private let showBranch: @MainActor (UUID) -> Void
    @ObservationIgnored private var prepared: PreparedNotionExport?
    /// Базы выгрузки и схемы, дочитанные для них из Notion (пусто — импорт по одним таблицам).
    @ObservationIgnored private var databaseIds: [String] = []
    @ObservationIgnored private var schema = NotionSchemaFetchResult()
    /// Ключ интеграции Notion: тот же, что для картинок.
    @ObservationIgnored private let notionKey: @Sendable () async throws -> String?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// «Остановить» импорта командой `mynotion import notion` (005): сам импорт идёт в обработчике команды.
    @ObservationIgnored private var stopCommandImport: (@MainActor () -> Void)?

    init(store: NotesStore, attachments: AttachmentStore? = nil, saveOpenPages: @escaping @MainActor () -> Bool,
         showBranch: @escaping @MainActor (UUID) -> Void,
         notionKey: @escaping @Sendable () async throws -> String? = { nil }) {
        self.notionKey = notionKey
        self.attachments = attachments
        self.store = store
        self.saveOpenPages = saveOpenPages
        self.showBranch = showBranch
    }

    var isBusy: Bool {
        switch state {
        case .preparing, .running, .confirmRepeat, .offerSchema, .fetchingSchema: true
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
        panel.prompt = "Перенести"
        panel.message = "Выберите файл, который сохранил Notion (меню «Export → Markdown & CSV», ZIP), или папку с распакованным файлом"
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
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<PreparedImport, any Error> in
                Result {
                    let prepared = try NotionExportUnpacker().prepare(source)
                    do {
                        return PreparedImport(export: prepared, databaseIds: prepared.databaseIds(),
                                              previous: try NotionImporter(store: store).previousImport(withFingerprint: prepared.fingerprint))
                    } catch {
                        prepared.discard()
                        throw error
                    }
                }
            }.value
            self?.didPrepare(outcome)
        }
    }

    /// Выгрузка, готовая к переносу: папка, id её баз и прежний перенос того же файла, если был.
    private struct PreparedImport: Sendable {
        let export: PreparedNotionExport
        let databaseIds: [String]
        let previous: NotionImportRun?
    }

    private func didPrepare(_ outcome: Result<PreparedImport, any Error>) {
        switch outcome {
        case .failure(let error):
            state = .failed(Self.message(for: error))
        case .success(let ready):
            prepared = ready.export
            databaseIds = ready.databaseIds
            schema = NotionSchemaFetchResult()
            if let previous = ready.previous {
                state = .confirmRepeat(previous: previous)
            } else {
                offerSchemaOrImport()
            }
        }
    }

    func confirmRepeat() {
        guard case .confirmRepeat = state else { return }
        offerSchemaOrImport()
    }

    func cancelRepeat() {
        guard case .confirmRepeat = state else { return }
        discardPrepared()
    }

    private func discardPrepared() {
        prepared?.discard()
        prepared = nil
        databaseIds = []
        schema = NotionSchemaFetchResult()
        state = .idle
    }

    /// Есть базы — предложить дочитать их схему из Notion; нет баз — сразу переносить.
    private func offerSchemaOrImport() {
        guard !databaseIds.isEmpty else {
            runImport()
            return
        }
        state = .preparing
        let notionKey = notionKey
        let count = databaseIds.count
        task = Task { [weak self] in
            let hasKey = ((try? await notionKey()) ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            guard let self, case .preparing = self.state else { return }
            self.state = .offerSchema(databaseCount: count, hasKey: hasKey)
        }
    }

    /// «Дочитать схему из Notion»: только чтение по ключу, потом перенос. Не вышло — перенос по таблицам, причина в итоге.
    func fetchSchemaAndImport() {
        guard case .offerSchema = state else { return }
        state = .fetchingSchema
        let fetch = NotionSchemaFetch(key: notionKey)
        let ids = databaseIds
        task = Task { [weak self] in
            let result = await fetch.fetch(databaseIds: ids)
            guard let self, case .fetchingSchema = self.state, !Task.isCancelled else { return }
            self.schema = result
            self.runImport()
        }
    }

    func importWithoutSchema() {
        guard case .offerSchema = state else { return }
        schema = NotionSchemaFetchResult()
        runImport()
    }

    func cancelSchemaOffer() {
        guard case .offerSchema = state else { return }
        discardPrepared()
    }

    private func runImport() {
        guard let prepared else { return }
        guard saveOpenPages() else {
            finish(.failure(NotionImportError.cannotWrite("правки открытой страницы не записались на диск, импорт не начат")))
            return
        }
        state = .running(NotionImportProgress(phase: .reading, done: 0, total: 0))
        let importer = NotionImporter(store: store, attachments: attachments)
        let schema = schema
        task = Task { [weak self] in
            let detached = Task.detached(priority: .userInitiated) { () -> Result<NotionImportReport, any Error> in
                Result {
                    try importer.importExport(prepared, schema: schema) { step in
                        Task { @MainActor in self?.report(step) }
                    }
                }
            }
            // «Остановить» отменяет эту задачу, а с ней — импорт в фоне.
            let outcome = await withTaskCancellationHandler { await detached.value } onCancel: { detached.cancel() }
            prepared.discard()
            self?.prepared = nil
            self?.databaseIds = []
            self?.schema = NotionSchemaFetchResult()
            self?.finish(outcome)
        }
    }

    /// Остановить импорт: ветка откатывается целиком. Пока схема читается из Notion, ничего ещё не записано.
    func stop() {
        switch state {
        case .running:
            task?.cancel()
            stopCommandImport?()
        case .fetchingSchema:
            task?.cancel()
            discardPrepared()
        default:
            break
        }
    }

    // MARK: Импорт командой (005)

    /// Импорт командой: та же карточка хода, меню «Импорт из Notion…» недоступно до конца.
    func beginCommandImport(stop: @escaping @MainActor () -> Void) {
        guard !isBusy else { return }
        stopCommandImport = stop
        state = .running(NotionImportProgress(phase: .reading, done: 0, total: 0))
    }

    func reportCommandImport(_ step: NotionImportProgress) {
        guard stopCommandImport != nil else { return }
        report(step)
    }

    /// Итог импорта командой получает агент: окно итога не открывается, страница Юрия остаётся на месте.
    func endCommandImport() {
        guard stopCommandImport != nil else { return }
        stopCommandImport = nil
        state = .idle
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
        error is CancellationError ? "Перенос остановлен. Уже перенесённые страницы убраны, прежние записи не тронуты."
            : error.localizedDescription
    }

    /// Состояние для галереи интерфейса, без настоящего импорта.
    func showPreview(_ preview: State) {
        state = preview
    }
}

/// Карточка внизу окна: ход переноса с кнопкой «Остановить» или понятная ошибка с «Закрыть».
struct NotionImportNoticeView: View {
    let controller: NotionImportController

    var body: some View {
        switch controller.state {
        case .preparing:
            NoticeCard(identifier: "notion-import-notice") {
                NoticeProgress(done: 0, total: 0, text: "Открываю файл из Notion…")
            }
        case .fetchingSchema:
            NoticeCard(identifier: "notion-import-notice") {
                NoticeProgress(done: 0, total: 0, text: "Читаю схему баз из Notion…")
                Button("Остановить") { controller.stop() }
                    .accessibilityIdentifier("notion-import-stop")
            }
        case .running(let step):
            NoticeCard(identifier: "notion-import-notice") {
                NoticeProgress(done: step.done, total: step.total, text: Self.progressText(step))
                Button("Остановить") { controller.stop() }
                    .accessibilityIdentifier("notion-import-stop")
            }
        case .failed(let message):
            NoticeCard(identifier: "notion-import-notice") {
                Text(verbatim: message).foregroundStyle(Color(nsColor: Palette.destructiveText))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Закрыть") { controller.dismiss() }
                    .accessibilityIdentifier("notion-import-close")
            }
        case .idle, .confirmRepeat, .offerSchema, .finished:
            EmptyView()
        }
    }

    /// «Перенесено страниц: 420 из 1 000»; пока файл читается — «Читаю файл из Notion: 420 из 1 000 страниц».
    static func progressText(_ step: NotionImportProgress) -> String {
        guard step.total > 0 else { return step.phase == .reading ? "Читаю файл из Notion…" : "Переношу страницы…" }
        return step.phase == .reading
            ? "Читаю файл из Notion: \(number(step.done)) из \(number(step.total)) страниц"
            : "Перенесено страниц: \(number(step.done)) из \(number(step.total))"
    }
}

/// Окна поверх страницы: «этот файл уже переносили — ещё раз?» и итог переноса.
struct NotionImportSheets: ViewModifier {
    let controller: NotionImportController?

    func body(content: Content) -> some View {
        content.modalCard(isPresented: isPresented) {
            if let controller {
                switch controller.state {
                case .confirmRepeat(let previous): NotionImportRepeatView(controller: controller, previous: previous)
                case .offerSchema(let count, let hasKey): NotionImportSchemaOfferView(controller: controller, databaseCount: count, hasKey: hasKey)
                case .finished(let report): NotionImportReportView(controller: controller, report: report)
                default: EmptyView()
                }
            }
        }
    }

    private var isPresented: Bool {
        switch controller?.state {
        case .confirmRepeat?, .offerSchema?, .finished?: true
        default: false
        }
    }
}

/// Итог (FR-026): сколько перенесено, где лежит, что из оформления Notion стало простым текстом.
struct NotionImportReportView: View {
    let controller: NotionImportController
    let report: NotionImportReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalCardTitle(text: "Перенос из Notion закончен")
            Text(verbatim: "Перенесено страниц: \(number(report.pageCount)). Они лежат на новой странице «\(report.rootTitle)» в списке слева.")
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("notion-import-summary")
            ForEach(report.notices, id: \.self) { notice in
                Text(verbatim: notice + ".")
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("notion-import-notice-line")
            }
            if !report.databases.isEmpty {
                Text(verbatim: Self.databasesIntro(report))
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    if report.databases.count > 2 || report.databases.contains(where: { $0.properties.count > 12 }) {
                        ScrollView { databaseList }.frame(height: 220)
                    } else {
                        databaseList
                    }
                }
                .background(Color(nsColor: Palette.pageBackground), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: Palette.border)))
                .accessibilityIdentifier("notion-import-databases")
            }
            if report.simplified.isEmpty {
                Text(report.notices.isEmpty ? "Всё перенесено как было." : "Остальное перенесено как было.")
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
            } else {
                Text("Кое-что из Notion здесь выглядеть так же не может. Текст сохранён, но обычными абзацами:")
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                // Короткий список — по высоте строк, длинный — с прокруткой: пустого места под строками нет.
                Group {
                    if report.simplified.count > 6 {
                        ScrollView { simplifiedList }.frame(height: 220)
                    } else {
                        simplifiedList
                    }
                }
                .background(Color(nsColor: Palette.pageBackground), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: Palette.border)))
                .accessibilityIdentifier("notion-import-simplified")
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Открыть страницу") { controller.openBranch(report) }
                    .buttonStyle(ModalCardButtonStyle())
                    .accessibilityIdentifier("notion-import-open-branch")
                Button("Готово") { controller.dismiss() }
                    .buttonStyle(ModalCardButtonStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("notion-import-done")
            }
            .padding(.top, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notion-import-report")
    }

    /// По базе: «Задачи — строк: 4, шаблонов: 1», типы свойств, что перенесено не целиком.
    private var databaseList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(report.databases.enumerated()), id: \.offset) { _, database in
                VStack(alignment: .leading, spacing: 2) {
                    (Text(verbatim: database.title.isEmpty ? "Без названия" : database.title).fontWeight(.medium)
                        + Text(verbatim: " — " + Self.rowsText(database)))
                    Text(verbatim: database.properties.joined(separator: "; "))
                        .foregroundStyle(Color(nsColor: Palette.textSecondary))
                    ForEach(database.notes, id: \.self) { note in
                        Text(verbatim: note + ".").foregroundStyle(Color(nsColor: Palette.textSecondary))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
    }

    /// Откуда взяты типы свойств: из схемы Notion, по значениям таблицы или и так и так.
    static func databasesIntro(_ report: NotionImportReport) -> String {
        let applied = report.databases.filter(\.schemaApplied).count
        if applied == 0 { return "Базы стали базами MyNotion. Типы свойств угаданы по значениям:" }
        if applied == report.databases.count { return "Базы стали базами MyNotion. Типы свойств, формулы и сводки взяты из схемы Notion:" }
        return "Базы стали базами MyNotion. Где схему Notion прочитать не удалось, типы угаданы по значениям:"
    }

    /// «строк: 4, шаблонов: 1».
    static func rowsText(_ database: DatabaseImportSummary) -> String {
        "строк: \(number(database.rowCount))" + (database.templateCount > 0 ? ", шаблонов: \(number(database.templateCount))" : "")
    }

    private var simplifiedList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(report.simplified.enumerated()), id: \.offset) { _, page in
                (Text(verbatim: page.pageTitle).fontWeight(.medium) + Text(verbatim: ": " + page.items.joined(separator: ", ")))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
    }
}

/// Выгрузка Notion не хранит формулы, сводки, цвета и статусы баз: предлагаем дочитать их по ключу интеграции (только чтение).
struct NotionImportSchemaOfferView: View {
    let controller: NotionImportController
    let databaseCount: Int
    let hasKey: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalCardTitle(text: "Дочитать схему баз из Notion?")
            Text(verbatim: "В файле баз: \(number(databaseCount)). Файл не хранит их формулы, сводки, цвета вариантов и статусы. Их можно дочитать из Notion по вашему ключу: приложение только читает, в Notion ничего не меняется.")
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: hasKey
                ? "Доступ нужен к каждой базе: в Notion откройте базу, «•••» → «Подключения» и добавьте свою интеграцию. Базы без доступа перенесутся по таблицам, причина будет в итоге."
                : "Ключа Notion пока нет. Добавьте его в «Настройки → Notion» (интеграция создаётся на notion.so/profile/integrations), затем вернитесь сюда. Можно и сейчас перенести по таблицам: типы свойств тогда угадываются по значениям.")
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("notion-import-schema-hint")
            HStack(spacing: 8) {
                Spacer()
                Button("Отмена") { controller.cancelSchemaOffer() }
                    .buttonStyle(ModalCardButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("notion-import-schema-cancel")
                Button("Перенести без схемы") { controller.importWithoutSchema() }
                    .buttonStyle(ModalCardButtonStyle(isPrimary: !hasKey))
                    .accessibilityIdentifier("notion-import-schema-skip")
                if hasKey {
                    Button("Дочитать схему из Notion") { controller.fetchSchemaAndImport() }
                        .buttonStyle(ModalCardButtonStyle(isPrimary: true))
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("notion-import-schema-fetch")
                }
            }
            .padding(.top, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notion-import-schema-offer")
    }
}

/// Повтор того же файла (FR-027): дубли молча не создаются.
struct NotionImportRepeatView: View {
    let controller: NotionImportController
    let previous: NotionImportRun

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalCardTitle(text: "Этот файл из Notion уже переносили")
            Text(verbatim: "\(Self.dateText(previous.startedAt)) из него перенесено страниц: \(number(previous.importedPages)). Если перенести ещё раз, рядом появится вторая копия этих страниц.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Отмена") { controller.cancelRepeat() }
                    .buttonStyle(ModalCardButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("notion-import-cancel-repeat")
                Button("Перенести ещё раз") { controller.confirmRepeat() }
                    .buttonStyle(ModalCardButtonStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("notion-import-again")
            }
            .padding(.top, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notion-import-repeat")
    }

    /// «18 октября 2026 в 15:04».
    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy 'в' HH:mm"
        return formatter.string(from: date)
    }
}
