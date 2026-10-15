import AppKit
import NotesCore
import SwiftUI
import VisualStyle

/// Открытая страница: верхняя полоса с путём, полоса ошибки сохранения и редактор
/// (contracts/visual-style.md, «Страница»). На каждую страницу — свой редактор: задавайте `.id(pageId)`.
public struct PageEditorView: View {
    let document: PageDocument
    /// Названия страниц-предков от корня; у корневой страницы — пусто.
    let ancestorTitles: [String]
    let initialFocus: PageTextView.InitialFocus
    /// Названия и иконки страниц для блоков-подстраниц.
    let linkedPages: [UUID: LinkedPage]
    let onOpenPage: @MainActor (UUID) -> Void
    let onReady: @MainActor () -> Void

    public init(document: PageDocument, ancestorTitles: [String] = [], initialFocus: PageTextView.InitialFocus,
                linkedPages: [UUID: LinkedPage] = [:], onOpenPage: @escaping @MainActor (UUID) -> Void = { _ in },
                onReady: @escaping @MainActor () -> Void = {}) {
        self.document = document
        self.ancestorTitles = ancestorTitles
        self.initialFocus = initialFocus
        self.linkedPages = linkedPages
        self.onOpenPage = onOpenPage
        self.onReady = onReady
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            if case .failed(let reason) = document.saveStatus {
                SaveStatusBanner(reason: reason)
            }
            PageTextEditor(document: document, initialFocus: initialFocus, linkedPages: linkedPages,
                           onOpenPage: onOpenPage, onReady: onReady)
                .overlay(alignment: .top) { scrollEdgeFade }
        }
        .background(Color(nsColor: Palette.pageBackground))
    }

    /// Путь «Родитель / Страница» шрифтом 14; длинный — без середины и с обрезанным по слову названием.
    private var topBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width - Metrics.Page.topBarHorizontalPadding - Metrics.Page.topBarTrailingInset
            Text(BreadcrumbText.fitting(ancestorTitles + [breadcrumbTitle], width: width, measure: BreadcrumbText.measure))
                .font(Font(Typography.breadcrumb.font))
                .foregroundStyle(Color(nsColor: Palette.textPrimary))
                .lineLimit(1)
                .accessibilityIdentifier("page-breadcrumb")
                .padding(.leading, Metrics.Page.topBarHorizontalPadding)
                .padding(.trailing, Metrics.Page.topBarTrailingInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: Metrics.Page.topBarHeight)
    }

    /// Прокрученный текст уходит под верхнюю полосу плавно, а не обрезанной строкой.
    private var scrollEdgeFade: some View {
        let background = Color(nsColor: Palette.pageBackground)
        let solid = Metrics.Page.scrollEdgeSolidHeight / Metrics.Page.scrollEdgeFadeHeight
        return LinearGradient(stops: [.init(color: background, location: 0), .init(color: background, location: solid),
                                      .init(color: background.opacity(0), location: 1)],
                              startPoint: .top, endPoint: .bottom)
            .frame(height: Metrics.Page.scrollEdgeFadeHeight)
            .allowsHitTesting(false)
    }

    private var breadcrumbTitle: String {
        let page = document.page
        return [page.icon, page.displayTitle].compactMap { $0 }.joined(separator: " ")
    }
}

/// `PageTextView` в прокрутке для SwiftUI.
struct PageTextEditor: NSViewRepresentable {
    let document: PageDocument
    let initialFocus: PageTextView.InitialFocus
    let linkedPages: [UUID: LinkedPage]
    let onOpenPage: @MainActor (UUID) -> Void
    let onReady: @MainActor () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PageTextView(document: document, initialFocus: initialFocus)
        textView.onReady = onReady
        textView.linkedPages = linkedPages
        textView.onOpenPage = onOpenPage
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.pageBackground
        scrollView.documentView = textView
        textView.frame.size.width = scrollView.contentSize.width
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PageTextView else { return }
        textView.linkedPages = linkedPages
        textView.onOpenPage = onOpenPage
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: ()) {
        (scrollView.documentView as? PageTextView)?.commitEdits()
    }
}
