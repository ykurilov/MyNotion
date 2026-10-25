import AppKit
import NotesCore
import Proofreading
import VisualStyle

/// «Исправить ошибки» (меню выделения): выделенный текст уходит исправителю, окно под выделением показывает правки,
/// «Заменить» (Enter) меняет текст одним шагом ⌘Z, «Отмена» (Esc) закрывает окно и обрывает запрос.
@MainActor
final class ProofreadController {
    weak var textView: PageTextView?
    private(set) var state: ProofreadPanelState?
    private var window: ProofreadPanelWindow?
    private var task: Task<Void, Never>?
    private var request: Request?
    /// Текст меняет сама замена: выделение сдвигается, окно закрывать не нужно.
    private var isReplacing = false
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// Что проверяется: подряд идущие блоки страницы, выделение на момент нажатия и куски с текстом.
    private struct Request {
        struct Piece {
            let blockId: UUID
            /// Выделенная часть текста блока, UTF-16.
            let range: Range<Int>
            /// Весь текст блока на момент нажатия.
            let original: InlineText
        }

        let selection: NSRange
        let blockIds: [UUID]
        let pieces: [Piece]
        let text: ProofreadText
        var corrected: [InlineText]?
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var isShown: Bool { state != nil }
    var panelView: ProofreadPanelView? { window?.panelView }
    /// Место карточки без тени, в координатах экрана.
    private(set) var cardFrame: NSRect?

    /// Блоки, в тексте которых правят ошибки: не код, не формула и не ссылка на страницу.
    static func isProofreadable(_ kind: BlockKind) -> Bool {
        !kind.rendersAsAttachment && ![.code, .equation, .pageLink].contains(kind)
    }

    func start(with proofreader: (any TextProofreader)?) {
        guard let textView else { return }
        cancel()
        textView.commitEdits()
        let selection = textView.selectedRange()
        guard selection.length > 0, let blocks = textView.selectedBlockRange() else { return }
        let document = textView.document
        let pieces = blocks.compactMap { index -> Request.Piece? in
            let block = document.blocks[index]
            let range = textView.localRange(of: selection, inBlockAt: index)
            guard Self.isProofreadable(block.kind), !range.isEmpty else { return nil }
            return Request.Piece(blockId: block.id, range: range, original: block.text)
        }
        let text = ProofreadText(segments: pieces.map { $0.original.slice($0.range) })
        request = Request(selection: selection, blockIds: document.blocks[blocks].map(\.id), pieces: pieces, text: text)
        guard !pieces.isEmpty, text.source.contains(where: { $0.isLetter }) else {
            return show(.failed("Здесь нечего проверять — выделите текст"))
        }
        guard let proofreader else { return show(.failed(ProofreadingError.unavailable.localizedDescription)) }
        show(.checking)
        let source = text.source
        task = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await proofreader.proofread(source)) } catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            self?.finish(result)
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard state == .checking, var request else { return }
        task = nil
        do {
            let corrected = try result.get()
            guard request.text.hasChanges(corrected) else { return show(.noErrors) }
            request.corrected = try request.text.apply(corrected)
            self.request = request
            let directory = textView?.mentionDirectory ?? MentionDirectory()
            let visible: (InlineText) -> String = { $0.plainText(pageTitle: directory.plainTitle(of:)) }
            let before = request.text.displayText(of: request.text.source, visible: visible)
            let after = request.text.displayText(of: corrected, visible: visible)
            show(.corrections(WordDiff.pieces(from: before, to: after)))
        } catch is CancellationError {
            hide()
        } catch {
            show(.failed((error as? LocalizedError)?.errorDescription ?? ProofreadingError.badResponse.localizedDescription))
        }
    }

    /// «Заменить»: исправленные куски — в блоки одним шагом ⌘Z, выделение — по исправленному тексту.
    func replace() {
        guard case .corrections = state, let request, let corrected = request.corrected, let textView else { return }
        textView.commitEdits()
        let document = textView.document
        guard let firstId = request.blockIds.first, let first = document.index(ofBlock: firstId),
              first + request.blockIds.count <= document.blocks.count,
              document.blocks[first..<first + request.blockIds.count].map(\.id) == request.blockIds,
              request.pieces.allSatisfy({ piece in document.blocks.first { $0.id == piece.blockId }?.text == piece.original }) else {
            return show(.failed(ProofreadingError.textChanged.localizedDescription))
        }
        let range = first..<first + request.blockIds.count
        var drafts = document.blocks[range].map(BlockDraft.init)
        for (piece, text) in zip(request.pieces, corrected) {
            guard let offset = request.blockIds.firstIndex(of: piece.blockId) else { continue }
            drafts[offset].text = piece.original.replacing(piece.range, with: text)
        }
        isReplacing = true
        textView.changeBlocks(range, to: drafts, actionName: "Исправить ошибки")
        if let firstPiece = request.pieces.first, let lastPiece = request.pieces.last, let lastText = corrected.last,
           let startBlock = request.blockIds.firstIndex(of: firstPiece.blockId), let endBlock = request.blockIds.firstIndex(of: lastPiece.blockId) {
            let start = textView.mapper.paragraphStart(ofBlockAt: first + startBlock) + firstPiece.range.lowerBound
            let end = textView.mapper.paragraphStart(ofBlockAt: first + endBlock) + lastPiece.range.lowerBound + lastText.string.utf16.count
            textView.setSelectedRange(NSRange(location: start, length: max(0, end - start)))
        }
        isReplacing = false
        hide()
    }

    /// «Отмена», Esc, щелчок мимо: окно закрывается, запрос обрывается.
    func cancel() {
        task?.cancel()
        task = nil
        hide()
    }

    private func hide() {
        let wasShown = isShown
        state = nil
        request = nil
        cardFrame = nil
        window?.hide()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if wasShown, !isReplacing { textView?.updateFormatBar() }
    }

    /// Выделение сдвинули (щелчок, стрелки, набор) — окно больше не про него.
    func selectionDidChange(_ selection: NSRange) {
        guard isShown, !isReplacing, selection != request?.selection else { return }
        cancel()
    }

    /// Enter — «Заменить» (или закрыть сообщение), Esc — «Отмена».
    func handleCommand(_ selector: Selector) -> Bool {
        guard let state else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if case .corrections = state { replace() } else if state != .checking { cancel() }
        case #selector(NSResponder.cancelOperation(_:)): cancel()
        default: return false
        }
        return true
    }

    // MARK: Окно

    private func show(_ state: ProofreadPanelState) {
        self.state = state
        let window = window ?? makeWindow()
        window.panelView.state = state
        place()
        if observers.isEmpty { observe() }
    }

    /// Под последней строкой выделения, левым краем у начала выделения; внизу не помещается — над первой строкой.
    private func place() {
        guard let textView, let window, let parent = textView.window, let request else { return }
        let storageLength = textView.textStorage?.length ?? 0
        let selection = request.selection
        guard NSMaxRange(selection) <= storageLength, selection.length > 0 else { return }
        let first = textView.firstRect(forCharacterRange: NSRange(location: selection.location, length: 1), actualRange: nil)
        let last = textView.firstRect(forCharacterRange: NSRange(location: NSMaxRange(selection) - 1, length: 1), actualRange: nil)
        let visible = parent.convertToScreen(textView.convert(textView.visibleRect, to: nil))
        let size = window.panelView.fittingCardSize
        let spacing = Metrics.FormatBar.selectionSpacing
        var origin = NSPoint(x: first.minX, y: last.minY - spacing - size.height)
        if origin.y < visible.minY { origin.y = first.maxY + spacing }
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        let card = NSRect(origin: origin, size: size)
        if card != cardFrame || window.parent == nil {
            cardFrame = card
            window.show(card: card, parent: parent)
        }
    }

    private func makeWindow() -> ProofreadPanelWindow {
        let window = ProofreadPanelWindow()
        window.panelView.onReplace = { [weak self] in self?.replace() }
        window.panelView.onCancel = { [weak self] in self?.cancel() }
        self.window = window
        return window
    }

    /// Приложение ушло в фон — окно закрывается; прокрутка — окно следует за выделением.
    private func observe() {
        observers.append(PopupWindows.onAppDeactivation { [weak self] in self?.cancel() })
        if let clip = textView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.place() }
            })
        }
    }
}

extension PageTextView {
    /// Исправитель для «Исправить ошибки»: ставит приложение при запуске; `nil` — окно сообщает, что недоступно.
    public static var proofreader: (any TextProofreader)?

    /// «Исправить ошибки» над выделенным текстом.
    func startProofreading() {
        formatBar.hide()
        proofreading.start(with: Self.proofreader)
    }
}
