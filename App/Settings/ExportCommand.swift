import AppKit
import Attachments
import MarkdownExport
import NotesCore
import Observation
import SwiftUI
import VisualStyle

/// «Файл → Выгрузить в Markdown…», ⌘⇧E (FR-017, contracts/editor-interactions.md).
struct ExportCommands: Commands {
    let controller: MarkdownExportController?

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Выгрузить в Markdown…") { controller?.chooseFolderAndExport() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(controller == nil || controller?.isRunning == true)
        }
    }
}

/// Выгрузка в фоне: окно не замирает, ход виден в уведомлении над страницей, в конце — «Показать в Finder».
@MainActor
@Observable
final class MarkdownExportController {
    enum State: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished(folder: URL, pageCount: Int, missingFiles: Int = 0)
        case failed(String)
    }

    private(set) var state = State.idle
    @ObservationIgnored private let store: NotesStore
    /// Копии файлов: в выгрузку — в папку страницы; нескачанные — строкой и счётом в итоге.
    @ObservationIgnored private let attachments: AttachmentStore?
    /// Записать правки открытых страниц на диск: в выгрузку попадает то, что на экране. `false` — не записалось.
    @ObservationIgnored private let saveOpenPages: @MainActor () -> Bool
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: NotesStore, attachments: AttachmentStore? = nil, saveOpenPages: @escaping @MainActor () -> Bool) {
        self.attachments = attachments
        self.store = store
        self.saveOpenPages = saveOpenPages
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func chooseFolderAndExport() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выгрузить сюда"
        panel.message = "Выберите папку: в ней появится папка «MyNotion-выгрузка-…» со всеми записями"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        export(into: folder)
    }

    func export(into folder: URL) {
        guard !isRunning else { return }
        guard saveOpenPages() else {
            state = .failed("Правки открытой страницы не записались на диск, поэтому выгрузка не начата. Попробуйте ещё раз.")
            return
        }
        state = .running(done: 0, total: 0)
        let attachments = attachments
        let exporter = MarkdownExporter(store: store, attachmentFile: { attachments?.fileURL(for: $0) })
        task = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<MarkdownExportResult, any Error> in
                Result {
                    try exporter.export(into: folder) { step in
                        // Не на каждую страницу: окну хватает десяти обновлений в секунду.
                        guard step.pagesDone % 10 == 0 || step.pagesDone == step.pagesTotal else { return }
                        Task { @MainActor in self?.report(step) }
                    }
                }
            }.value
            self?.finish(outcome)
        }
    }

    func dismissNotice() {
        guard !isRunning else { return }
        state = .idle
    }

    private func report(_ step: MarkdownExportProgress) {
        guard isRunning else { return }
        state = .running(done: step.pagesDone, total: step.pagesTotal)
    }

    private func finish(_ outcome: Result<MarkdownExportResult, any Error>) {
        switch outcome {
        case .success(let result): state = .finished(folder: result.folder, pageCount: result.pageCount, missingFiles: result.missingFileCount)
        case .failure(let error): state = .failed(error.localizedDescription)
        }
    }

    func showInFinder(_ folder: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Состояние для галереи интерфейса, без настоящей выгрузки.
    func showPreview(_ preview: State) {
        state = preview
    }
}

/// Карточка внизу окна: ход выгрузки, итог с кнопкой «Показать в Finder» или понятная ошибка — в той же манере,
/// что перенос из Notion (contracts/visual-style.md, «Карточки хода»).
struct ExportNoticeView: View {
    let controller: MarkdownExportController

    var body: some View {
        switch controller.state {
        case .idle:
            EmptyView()
        case .running(let done, let total):
            NoticeCard(identifier: "export-notice") {
                NoticeProgress(done: done, total: total,
                               text: total > 0 ? "Выгружено в Markdown страниц: \(number(done)) из \(number(total))" : "Выгружаю в Markdown…")
            }
        case .finished(let folder, let pageCount, let missingFiles):
            NoticeCard(identifier: "export-notice") {
                Text(verbatim: "Выгружено в Markdown страниц: \(number(pageCount))")
                if missingFiles > 0 {
                    Text(verbatim: MarkdownExportResult.missingFilesMessage(count: missingFiles))
                        .foregroundStyle(Color(nsColor: Palette.textSecondary))
                }
                Button("Показать в Finder") { controller.showInFinder(folder) }
                    .accessibilityIdentifier("export-show-in-finder")
                closeButton
            }
        case .failed(let message):
            NoticeCard(identifier: "export-notice") {
                Text(verbatim: message).foregroundStyle(Color(nsColor: Palette.destructiveText))
                    .fixedSize(horizontal: false, vertical: true)
                closeButton
            }
        }
    }

    private var closeButton: some View {
        Button("Закрыть") { controller.dismissNotice() }
            .accessibilityIdentifier("export-close")
    }
}
