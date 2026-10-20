import AppKit
import NotesCore
import PageCover
import PageEditor
import VisualStyle

/// Обложка версии в просмотре: только вид, без кнопок и окна «Сменить обложку».
@MainActor
final class VersionCoverAddon: PageHeaderAddon {
    private weak var model: MainWindowModel?

    static func factory(_ model: MainWindowModel) -> PageHeaderAddonFactory {
        { [weak model] _ in VersionCoverAddon(model: model) }
    }

    init(model: MainWindowModel?) {
        self.model = model
    }

    func install(in textView: PageTextView) {
        pageDidChange(textView.document.page, in: textView)
    }

    func pageDidChange(_ page: Page, in textView: PageTextView) {
        guard let cover = page.cover else { return }
        let view = CoverView(cover: cover) { [weak model] id in model?.coverFileURL(id) }
        let area = (textView.enclosingScrollView?.frame.height ?? 600) + Metrics.Page.topBarHeight
        textView.setCover(view, height: Metrics.PageCover.height(forPageAreaHeight: area))
    }
}
