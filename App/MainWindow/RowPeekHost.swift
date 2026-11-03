import AppKit
import DatabaseGrid
import Databases
import Navigation
import NotesCore
import PageEditor
import SwiftUI
import VisualStyle

/// Просмотр строки базы поверх окна (contracts/database-ui.md, «Страница строки»; Notion 7.39 Side peek и Center peek).
/// **Сбоку** — панель справа на высоту страницы (≈ 45 % ширины окна), вид таблицы слева рабочий; **по центру** —
/// карточка ≈ 775×610 поверх затемнения, щелчок мимо закрывает. Вверху «»» (закрыть) и «⤢» (на всю страницу),
/// Esc закрывает. Внутри — обычный редактор страницы строки со свойствами под названием.
struct RowPeekHost: View {
    @Bindable var model: MainWindowModel
    /// Какой просмотр рисует этот слой: сбоку — над страницей, по центру — над всем окном.
    let mode: RowOpenMode
    /// Ширина боковой панели слева от страницы: панель сбоку считается от ширины окна.
    var sidebarWidth: CGFloat = 0
    let mentions: MentionSettings
    let linkedPages: [UUID: LinkedPage]

    var body: some View {
        ZStack {
            if let peek = model.rowPeek, peek.mode == mode {
                switch mode {
                case .sidePeek: sidePanel(peek)
                case .centerPeek: centerCard(peek)
                case .fullPage: EmptyView()
                }
            }
        }
        .animation(.easeOut(duration: Metrics.RowPage.peekAnimationDuration), value: model.rowPeek?.document.pageId)
    }

    private func sidePanel(_ peek: RowPeek) -> some View {
        GeometryReader { proxy in
            let metrics = Metrics.RowPage.self
            let windowWidth = proxy.size.width + sidebarWidth
            let width = min(max(windowWidth * metrics.sidePeekWidthFraction, metrics.sidePeekMinWidth), proxy.size.width)
            HStack(spacing: 0) {
                // Слева — таблица: щелчки проходят к ней.
                Spacer(minLength: 0).allowsHitTesting(false)
                editor(peek)
                    .frame(width: width)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: Palette.border)).frame(width: 1) }
                    .shadow(color: .black.opacity(0.08), radius: 12, x: -4)
                    // Своя группа: метки кнопок и полосы шаблона внутри не затираются меткой карточки.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("row-side-peek")
            }
        }
        .transition(.move(edge: .trailing))
    }

    private func centerCard(_ peek: RowPeek) -> some View {
        GeometryReader { proxy in
            let metrics = Metrics.RowPage.self
            ZStack {
                Color(nsColor: Palette.modalBackdrop)
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeRowPeek() }
                editor(peek)
                    .frame(width: min(metrics.centerPeekWidth, proxy.size.width - 2 * metrics.centerPeekMargin),
                           height: min(metrics.centerPeekHeight, proxy.size.height - 2 * metrics.centerPeekMargin))
                    .clipShape(RoundedRectangle(cornerRadius: metrics.centerPeekCornerRadius))
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("row-center-peek")
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private func editor(_ peek: RowPeek) -> some View {
        let document = peek.document
        return PageEditorView(
            document: document,
            initialFocus: peek.focus,
            linkedPages: linkedPages,
            onOpenPage: { model.open(PageOpenRequest.fromClick($0)) },
            onSubpageRequest: { model.handleSubpageRequest($0, inPage: document.pageId) },
            onSetIcon: { model.setIcon(document.pageId, to: $0) },
            onResolveConflict: { model.resolveConflict($0, in: document) },
            blockViewState: model.blockViewState,
            mentions: mentions,
            pageMenuItems: PageMenuItems.all(for: model, pageId: document.pageId),
            headerAddons: [PageCoverAddon.factory(model), model.rowPageAddonFactory(compactTitle: peek.mode == .sidePeek), BacklinksAddon.factory(model)],
            templates: TemplateSettings(templates: model.templateChoices(forPage: document.pageId),
                                        choose: { model.fillOpenPage(document.pageId, fromTemplate: $0) }),
            topBarLeading: AnyView(RowPeekBar(close: { model.closeRowPeek() }, expand: { model.expandRowPeek() }))
        )
        .overlay(alignment: .top) {
            if document.page.isTemplate, let databaseId = document.page.parentId {
                RowTemplateBanner(databaseTitle: model.tree.page(databaseId)?.title ?? "").padding(.top, Metrics.Page.topBarHeight)
            }
        }
        // Новая строка в просмотре — новый редактор.
        .id(ObjectIdentifier(document))
        .background(RowPeekEscape(rowId: document.pageId) { model.closeRowPeek() })
    }
}

/// Янтарная полоса над шаблоном строки (`notion-template-editor.png`): правки идут в шаблон, а не в строку.
private struct RowTemplateBanner: View {
    let databaseTitle: String

    var body: some View {
        Text("Вы правите шаблон в «\(databaseTitle.isEmpty ? "Без названия" : databaseTitle)»")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color(nsColor: Palette.templateBannerText))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(Color(nsColor: Palette.templateBannerBackground))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("row-template-banner")
    }
}

/// «»» — закрыть, «⤢» — на всю страницу (как кнопки Side peek у Notion, слева вверху).
private struct RowPeekBar: View {
    let close: () -> Void
    let expand: () -> Void

    var body: some View {
        HStack(spacing: Metrics.RowPage.peekButtonSpacing) {
            RowPeekButton(symbol: "chevron.right.2", label: "Закрыть", identifier: "row-peek-close", action: close)
            RowPeekButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Открыть на всю страницу", identifier: "row-peek-expand", action: expand)
        }
        .padding(.leading, Metrics.RowPage.peekBarLeading)
    }
}

private struct RowPeekButton: View {
    let symbol: String
    let label: String
    let identifier: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color(nsColor: Palette.windowToolbarIcon))
                .frame(width: Metrics.RowPage.peekButtonSize, height: Metrics.RowPage.peekButtonSize)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: isHovered ? Palette.hoverBackground : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// Esc закрывает просмотр, если ввод — в тексте строки или ни у кого. Поле правки (название, значение свойства)
/// сначала заканчивает правку своим Esc; таблица и страница слева свой Esc оставляют себе.
private struct RowPeekEscape: NSViewRepresentable {
    let rowId: UUID
    let close: @MainActor () -> Void

    func makeNSView(context: Context) -> Watcher { Watcher(rowId: rowId, close: close) }
    func updateNSView(_ nsView: Watcher, context: Context) { nsView.close = close }

    final class Watcher: NSView {
        let rowId: UUID
        var close: @MainActor () -> Void
        private var monitor: Any?

        init(rowId: UUID, close: @escaping @MainActor () -> Void) {
            self.rowId = rowId
            self.close = close
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty,
                  let window, event.window === window else { return event }
            switch window.firstResponder {
            case let text as PageTextView where text.document.pageDocument.pageId == rowId: close()
            // Таблица слева без правки ячейки: как в Notion, Esc закрывает открытую строку.
            case let view as NSView where Self.isInDatabaseGrid(view): close()
            // Поле правки NSTextField: Esc заканчивает правку.
            case is NSView: return event
            default: close()
            }
            return nil
        }

        /// Получатель клавиш — сама сетка таблицы (не поле правки ячейки внутри неё).
        static func isInDatabaseGrid(_ view: NSView) -> Bool {
            guard !(view is NSText) else { return false }
            var current: NSView? = view
            while let candidate = current {
                if candidate is DatabaseGridView { return true }
                current = candidate.superview
            }
            return false
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}
