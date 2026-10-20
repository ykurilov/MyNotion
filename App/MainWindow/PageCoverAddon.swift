import AppKit
import NotesCore
import PageCover
import PageEditor
import VisualStyle

/// Обложка в шапке открытой страницы (US1; contracts/pages-ui.md, «Шапка страницы»): «Добавить обложку» в строке
/// кнопок, вид обложки в месте «обложка», окно «Сменить обложку» и «Переместить». Правки — через окно (`MainWindowModel`),
/// показ — по странице документа (`pageDidChange`), так же приходят ⌘Z и правки с другого Mac.
@MainActor
final class PageCoverAddon: PageHeaderAddon {
    private weak var model: MainWindowModel?
    private let pageId: UUID
    private weak var textView: PageTextView?
    private let addCoverButton = PageHeaderButton(symbolName: "photo", title: "Добавить обложку", identifier: "add-page-cover")
    private var coverView: CoverView?
    private let picker = CoverPickerController()
    nonisolated(unsafe) private var frameObserver: NSObjectProtocol?

    static func factory(_ model: MainWindowModel) -> PageHeaderAddonFactory {
        { [weak model] document in PageCoverAddon(model: model, pageId: document.pageId) }
    }

    init(model: MainWindowModel?, pageId: UUID) {
        self.model = model
        self.pageId = pageId
    }

    deinit {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
    }

    func install(in textView: PageTextView) {
        self.textView = textView
        addCoverButton.onPress = { [weak self] in
            guard let self else { return }
            self.model?.addRandomCover(self.pageId)
        }
        textView.header.addButton(addCoverButton)
        // Высота обложки — доля высоты области страницы: следует за размером окна.
        if let scrollView = textView.enclosingScrollView {
            scrollView.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView,
                                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateHeight() }
            }
        }
        pageDidChange(textView.document.page, in: textView)
    }

    func pageDidChange(_ page: Page, in textView: PageTextView) {
        addCoverButton.isAvailable = page.cover == nil
        guard let cover = page.cover else {
            picker.close()
            if coverView != nil { textView.setCover(nil, height: 0) }
            coverView = nil
            return
        }
        if let coverView {
            coverView.show(cover)
        } else {
            let view = CoverView(cover: cover) { [weak model] id in model?.coverFileURL(id) }
            view.onChangeCover = { [weak self] anchor in self?.openPicker(below: anchor) }
            view.onSaveOffset = { [weak self] offset in
                guard let self else { return }
                self.model?.repositionCover(self.pageId, offset: offset)
            }
            coverView = view
            textView.setCover(view, height: coverHeight(in: textView))
        }
    }

    private func coverHeight(in textView: PageTextView) -> CGFloat {
        // Область страницы — прокрутка и верхняя полоса над ней, как `30vh` у Notion.
        let area = (textView.enclosingScrollView?.frame.height ?? 0) + Metrics.Page.topBarHeight
        return Metrics.PageCover.height(forPageAreaHeight: area)
    }

    private func updateHeight() {
        guard let textView, let coverView else { return }
        let height = coverHeight(in: textView)
        guard height != coverView.frame.height else { return }
        textView.setCover(coverView, height: height)
    }

    private func openPicker(below anchor: NSRect) {
        guard let window = textView?.window else { return }
        picker.show(below: anchor, in: window) { [weak self] choice in
            guard let self, let model = self.model else { return }
            switch choice {
            case .gallery(let id): model.setGalleryCover(id, on: self.pageId)
            case .file(let url): model.setImageCover(from: url, on: self.pageId)
            case .remove: model.removeCover(self.pageId)
            }
        }
    }
}
