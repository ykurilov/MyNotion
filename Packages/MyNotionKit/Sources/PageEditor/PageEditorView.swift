import AppKit
import NotesCore
import SwiftUI
import VisualStyle

/// Открытая страница: верхняя полоса с путём, полоса ошибки сохранения и редактор
/// (contracts/visual-style.md, «Страница»). На каждую страницу — свой редактор: задавайте `.id(pageId)`.
public struct PageEditorView: View {
    let document: PageDocument
    /// Названия страниц-предков с иконками, от корня; у корневой страницы — пусто.
    let ancestorTitles: [String]
    let initialFocus: PageTextView.InitialFocus
    /// Названия и иконки страниц для блоков-подстраниц.
    let linkedPages: [UUID: LinkedPage]
    let onOpenPage: @MainActor (UUID) -> Void
    /// «Страница» в меню «/» или «Преобразовать в»: создать подстраницу со ссылкой у блока.
    let onSubpageRequest: @MainActor (SubpageRequest) -> Void
    /// Выбрана иконка страницы (`nil` — убрать): правку делает владелец дерева, иконка возвращается в `document`.
    let onSetIcon: @MainActor (String?) -> Void
    /// Выбрана версия в «Двух версиях»: снять конфликт в базе.
    let onResolveConflict: @MainActor (Conflict) -> Void
    /// Свёрнутые переключатели этого Mac.
    let blockViewState: BlockViewStateStore?
    /// Перейти к блоку (поиск страниц): свёрнутые предки раскрываются.
    let blockReveal: BlockReveal?
    let onReady: @MainActor () -> Void
    /// Упоминания и даты (US3): справочник страниц, поиск для окна «@», разрешение на уведомления.
    let mentions: MentionSettings
    /// Меню «•••» справа в верхней полосе (003); пусто — кнопки нет.
    let pageMenuItems: [PageMenuItem]
    /// Место слева от «•••» (US2: «☆»).
    let topBarAccessory: AnyView?

    public init(document: PageDocument, ancestorTitles: [String] = [], initialFocus: PageTextView.InitialFocus,
                linkedPages: [UUID: LinkedPage] = [:], onOpenPage: @escaping @MainActor (UUID) -> Void = { _ in },
                onSubpageRequest: @escaping @MainActor (SubpageRequest) -> Void = { _ in },
                onSetIcon: @escaping @MainActor (String?) -> Void = { _ in },
                onResolveConflict: @escaping @MainActor (Conflict) -> Void = { _ in },
                blockViewState: BlockViewStateStore? = nil, blockReveal: BlockReveal? = nil,
                onReady: @escaping @MainActor () -> Void = {}, mentions: MentionSettings = MentionSettings(),
                pageMenuItems: [PageMenuItem] = [], topBarAccessory: AnyView? = nil) {
        self.document = document
        self.ancestorTitles = ancestorTitles
        self.initialFocus = initialFocus
        self.linkedPages = linkedPages
        self.onOpenPage = onOpenPage
        self.onSubpageRequest = onSubpageRequest
        self.onSetIcon = onSetIcon
        self.onResolveConflict = onResolveConflict
        self.blockViewState = blockViewState
        self.blockReveal = blockReveal
        self.onReady = onReady
        self.mentions = mentions
        self.pageMenuItems = pageMenuItems
        self.topBarAccessory = topBarAccessory
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            if case .failed(let reason) = document.saveStatus {
                SaveStatusBanner(reason: reason)
            }
            PageTextEditor(document: document, icon: document.page.icon, initialFocus: initialFocus, linkedPages: linkedPages,
                           onOpenPage: onOpenPage, onSubpageRequest: onSubpageRequest, onSetIcon: onSetIcon, onResolveConflict: onResolveConflict,
                           blockViewState: blockViewState, blockReveal: blockReveal, onReady: onReady,
                           mentions: mentions)
                .overlay(alignment: .top) { scrollEdgeFade }
        }
        .background(Color(nsColor: Palette.pageBackground))
    }

    /// Путь «Родитель / Страница» шрифтом 14, «/» тусклый; длинный — без середины и с обрезанным по слову названием.
    private var topBar: some View {
        HStack(spacing: Metrics.Page.topBarButtonSpacing) {
            GeometryReader { proxy in
                let width = proxy.size.width - Metrics.Page.topBarHorizontalPadding - Metrics.Page.topBarTrailingInset
                Text(BreadcrumbText.styled(BreadcrumbText.fitting(ancestorTitles + [document.page.pathTitle], width: width,
                                                                  measure: BreadcrumbText.measure)))
                    .lineLimit(1)
                    .accessibilityIdentifier("page-breadcrumb")
                    .padding(.leading, Metrics.Page.topBarHorizontalPadding)
                    .padding(.trailing, Metrics.Page.topBarTrailingInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            if let topBarAccessory { topBarAccessory }
            if !pageMenuItems.isEmpty {
                PageMenuButton(items: pageMenuItems) { [document] in
                    PageMenuContext(page: document.page, wordCount: PageMenuFooter.wordCount(of: document))
                }
                .frame(width: Metrics.Page.topBarButtonSize, height: Metrics.Page.topBarButtonSize)
                .padding(.trailing, Metrics.Page.topBarHorizontalPadding)
            }
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
}

/// `PageTextView` в прокрутке для SwiftUI.
struct PageTextEditor: NSViewRepresentable {
    let document: PageDocument
    /// Иконка отдельно от документа: её смена должна обновить шапку.
    let icon: String?
    let initialFocus: PageTextView.InitialFocus
    let linkedPages: [UUID: LinkedPage]
    let onOpenPage: @MainActor (UUID) -> Void
    let onSubpageRequest: @MainActor (SubpageRequest) -> Void
    let onSetIcon: @MainActor (String?) -> Void
    let onResolveConflict: @MainActor (Conflict) -> Void
    let blockViewState: BlockViewStateStore?
    let blockReveal: BlockReveal?
    let onReady: @MainActor () -> Void
    var mentions = MentionSettings()

    /// Какой запрос перехода к блоку редактор уже выполнил.
    final class Coordinator {
        var revealToken: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PageTextView(document: document, initialFocus: initialFocus)
        textView.blockViewState = blockViewState
        let reveal = blockReveal
        context.coordinator.revealToken = reveal?.token
        textView.onReady = { [weak textView, onReady] in
            onReady()
            if let reveal { textView?.revealBlock(reveal.blockId) }
        }
        textView.linkedPages = linkedPages
        textView.onOpenPage = onOpenPage
        textView.onSubpageRequest = onSubpageRequest
        textView.onSetIcon = onSetIcon
        textView.onResolveConflict = onResolveConflict
        mentions.apply(to: textView)
        return Self.makeScrollView(around: textView)
    }

    /// Прокрутка страницы: полоса только у длинной страницы.
    static func makeScrollView(around textView: PageTextView, frame: NSRect = .zero) -> NSScrollView {
        let scrollView = PageScrollView(frame: frame)
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
        textView.onSubpageRequest = onSubpageRequest
        textView.onSetIcon = onSetIcon
        textView.onResolveConflict = onResolveConflict
        mentions.apply(to: textView)
        textView.showIcon(icon)
        if let blockReveal, blockReveal.token != context.coordinator.revealToken {
            context.coordinator.revealToken = blockReveal.token
            textView.revealBlock(blockReveal.blockId)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        (scrollView.documentView as? PageTextView)?.commitEdits()
    }
}

/// Запрос перейти к блоку страницы; новый запрос — новый `token`, даже к тому же блоку.
public struct BlockReveal: Equatable, Sendable {
    public let blockId: UUID
    public let token: Int

    public init(blockId: UUID, token: Int) {
        self.blockId = blockId
        self.token = token
    }
}
