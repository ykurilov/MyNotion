import AppKit
import NotesCore
import SwiftUI
import VisualStyle

/// Открытая страница: верхняя полоса с путём, полоса ошибки сохранения и редактор
/// (contracts/visual-style.md, «Страница»). На каждый документ — свой редактор (`.id` внутри).
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
    /// Слева в верхней полосе вместо пути (004: просмотр строки — «»» и «⤢»).
    let topBarLeading: AnyView?
    /// Добавки шапки (US1: обложка); создаются один раз на редактор.
    let headerAddons: [PageHeaderAddonFactory]
    /// Вкладки (US3): окно читает место прокрутки открытой страницы, когда уходит с неё.
    let scrollPlace: PageScrollPlace?
    /// Вкладки (US3): место прокрутки, на которое встать после открытия («назад», переключение вкладки).
    let restoringScroll: TabScroll?
    /// Шаблоны для строк на пустой странице (US7).
    let templates: TemplateSettings

    public init(document: PageDocument, ancestorTitles: [String] = [], initialFocus: PageTextView.InitialFocus,
                linkedPages: [UUID: LinkedPage] = [:], onOpenPage: @escaping @MainActor (UUID) -> Void = { _ in },
                onSubpageRequest: @escaping @MainActor (SubpageRequest) -> Void = { _ in },
                onSetIcon: @escaping @MainActor (String?) -> Void = { _ in },
                onResolveConflict: @escaping @MainActor (Conflict) -> Void = { _ in },
                blockViewState: BlockViewStateStore? = nil, blockReveal: BlockReveal? = nil,
                onReady: @escaping @MainActor () -> Void = {}, mentions: MentionSettings = MentionSettings(),
                pageMenuItems: [PageMenuItem] = [], topBarAccessory: AnyView? = nil, headerAddons: [PageHeaderAddonFactory] = [],
                scrollPlace: PageScrollPlace? = nil, restoringScroll: TabScroll? = nil,
                templates: TemplateSettings = TemplateSettings(), topBarLeading: AnyView? = nil) {
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
        self.headerAddons = headerAddons
        self.scrollPlace = scrollPlace
        self.restoringScroll = restoringScroll
        self.templates = templates
        self.topBarLeading = topBarLeading
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
                           mentions: mentions, headerAddons: headerAddons, scrollPlace: scrollPlace, restoringScroll: restoringScroll,
                           templates: templates)
                // Новый документ — новый редактор (страницу открыли или перечитали после операции с деревом); верхняя
                // полоса остаётся и только обновляется: её пересоздание стоило каждому переходу (профиль вкладок, 003).
                .id(ObjectIdentifier(document))
                // У страницы с обложкой затухания нет, как у Notion: оно легло бы светлой полосой на верх обложки.
                .overlay(alignment: .top) { if document.page.cover == nil { scrollEdgeFade } }
        }
        .background(Color(nsColor: Palette.pageBackground))
    }

    /// Путь «Родитель / Страница» шрифтом 14, «/» тусклый; длинный — без середины и с обрезанным по слову названием.
    private var topBar: some View {
        HStack(spacing: Metrics.Page.topBarButtonSpacing) {
            if let topBarLeading {
                topBarLeading.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                breadcrumb
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

    private var breadcrumb: some View {
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
    var headerAddons: [PageHeaderAddonFactory] = []
    var scrollPlace: PageScrollPlace?
    var restoringScroll: TabScroll?
    var templates = TemplateSettings()

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
        scrollPlace?.attach(textView)
        textView.pendingScrollPlace = restoringScroll
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
        templates.apply(to: textView)
        let scrollView = Self.makeScrollView(around: textView)
        textView.installHeaderAddons(headerAddons.map { $0(document) })
        return scrollView
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
        templates.apply(to: textView)
        textView.showIcon(icon)
        textView.showAppearance(of: document.page)
        if let blockReveal, blockReveal.token != context.coordinator.revealToken {
            context.coordinator.revealToken = blockReveal.token
            textView.revealBlock(blockReveal.blockId)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? PageTextView else { return }
        textView.commitEdits()
        // Строки абзацев видимой части: их фрагменты остаются у видов абзацев, которые AppKit может держать
        // дольше страницы. Отцеплять раскладку от текста целиком дорого (страница на 10 000 блоков — +30 мс
        // к переходу), а с окном на экране AppKit сам отпускает эти виды.
        if let layoutManager = textView.textLayoutManager, let viewport = layoutManager.textViewportLayoutController.viewportRange {
            layoutManager.textViewportLayoutController.delegate = nil
            layoutManager.enumerateTextLayoutFragments(from: viewport.location) { fragment in
                fragment.invalidateLayout()
                return fragment.rangeInElement.endLocation.compare(viewport.endLocation) == .orderedAscending
            }
        }
        detachSubviews(of: textView)
    }

    /// Нарисованное слоями закрытой страницы.
    private static func clearContents(of layer: CALayer?) {
        guard let layer else { return }
        layer.contents = nil
        layer.sublayers?.forEach(clearContents)
    }

    /// Виды закрытой страницы снимаются по одному, от глубоких к верхним, без нарисованного. AppKit подписывает виды
    /// на системные уведомления блоком, который держит вид, и отписывает при снятии вида с родителя: вид, отпущенный
    /// вместе с родителем, оставался подписанным. У окна вне экрана (служебные запуски) виды абзацев TextKit живут
    /// дольше страницы — без раскладки и рисунка они почти ничего не весят.
    /// Прокрутка внутри страницы (блок кода с длинными строками) своих частей — вида прокрутки, вида в нём и полос —
    /// не отдаёт: на снятие `contentView` AppKit бросает исключение. Их содержимое снимается, сами они уходят с прокруткой.
    static func detachSubviews(of view: NSView) {
        let keepsParts = view is NSScrollView || view is NSClipView
        for subview in view.subviews.reversed() {
            detachSubviews(of: subview)
            clearContents(of: subview.layer)
            if !keepsParts { subview.removeFromSuperview() }
        }
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
