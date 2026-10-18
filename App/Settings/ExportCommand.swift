import AppKit
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
        case finished(folder: URL, pageCount: Int)
        case failed(String)
    }

    private(set) var state = State.idle
    @ObservationIgnored private let store: NotesStore
    /// Записать правки открытых страниц на диск: в выгрузку попадает то, что на экране. `false` — не записалось.
    @ObservationIgnored private let saveOpenPages: @MainActor () -> Bool
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: NotesStore, saveOpenPages: @escaping @MainActor () -> Bool) {
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
        let exporter = MarkdownExporter(store: store)
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
        case .success(let result): state = .finished(folder: result.folder, pageCount: result.pageCount)
        case .failure(let error): state = .failed(error.localizedDescription)
        }
    }

    func showInFinder(_ folder: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

/// Карточка внизу окна: ход выгрузки, итог с кнопкой «Показать в Finder» или понятная ошибка.
struct ExportNoticeView: View {
    let controller: MarkdownExportController

    var body: some View {
        if controller.state != .idle {
            card
                .padding(.bottom, 20)
                .transition(.opacity)
                // Идентификатор на контейнере иначе прячет вложенные текст и кнопки от VoiceOver и UI-тестов.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("export-notice")
        }
    }

    private var card: some View {
        HStack(spacing: 12) {
            content
        }
        .font(.system(size: 14))
        .foregroundStyle(Color(nsColor: Palette.textPrimary))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .background(Color(nsColor: Palette.popupMenuBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: Palette.border)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            EmptyView()
        case .running(let done, let total):
            ProgressView().controlSize(.small)
            Text(total > 0 ? "Выгружаю в Markdown… \(done) из \(total)" : "Выгружаю в Markdown…")
        case .finished(let folder, let pageCount):
            Text("Выгружено страниц: \(pageCount)")
            Button("Показать в Finder") { controller.showInFinder(folder) }
                .accessibilityIdentifier("export-show-in-finder")
            closeButton
        case .failed(let message):
            Text(message).foregroundStyle(Color(nsColor: Palette.destructiveText))
            closeButton
        }
    }

    private var closeButton: some View {
        Button("Закрыть") { controller.dismissNotice() }
            .accessibilityIdentifier("export-close")
    }
}
