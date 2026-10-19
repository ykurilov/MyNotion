import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Панель форматирования у выделенного текста, как в Notion (FR-033; contracts/editor-interactions.md,
/// «Панель форматирования»): тип блока с выпадающим списком, жирный, курсив, подчёркнутый, зачёркнутый, код, ссылка.
@MainActor
@Suite("Панель форматирования")
struct FormatBarTests {
    nonisolated static let themes: [NSAppearance.Name] = [.aqua, .darkAqua]

    private func onScreenBars() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && ["format-bar", "kind-menu"].contains($0.accessibilityIdentifier()) }
    }

    // MARK: Когда видна

    @Test("Выделен текст в блоке — панель открыта с типом блока; окно страницы невидимо — на экран не выходит")
    func appearsForTextSelection() throws {
        let editor = try EditorFixture([.paragraph("один два три")])
        #expect(!editor.textView.formatBar.isShown)
        editor.select(inBlock: 0, "два")
        #expect(editor.textView.formatBar.isShown)
        #expect(editor.textView.formatBar.state?.kindTitle == "Текст")
        #expect(editor.textView.formatBar.cardFrame != nil, "Место панели посчитано")
        #expect(onScreenBars().isEmpty, "Панель вышла на экран поверх чужих программ")
    }

    @Test("Выделение текста через блоки — панель открыта; блоки разных типов — «Разные типы»")
    func appearsAcrossBlocks() throws {
        let editor = try EditorFixture([.heading(2, "Заголовок"), .paragraph("абзац"), .paragraph("ещё")])
        let start = editor.textLocation(ofBlock: 0) + 3
        editor.textView.setSelectedRange(NSRange(location: start, length: editor.textLocation(ofBlock: 1) + 2 - start))
        #expect(editor.textView.formatBar.isShown)
        #expect(editor.textView.formatBar.state?.kindTitle == "Разные типы")

        let second = editor.textLocation(ofBlock: 1) + 1
        editor.textView.setSelectedRange(NSRange(location: second, length: editor.textLocation(ofBlock: 2) + 2 - second))
        #expect(editor.textView.formatBar.state?.kindTitle == "Текст", "Оба блока — абзацы")
    }

    @Test("Нет панели при курсоре без выделения и в режиме выделения блоков")
    func hiddenForCaretAndBlockMode() throws {
        let editor = try EditorFixture([.paragraph("один два"), .paragraph("три")])
        editor.placeCaret(inBlock: 0, at: 2)
        #expect(!editor.textView.formatBar.isShown)

        editor.select(inBlock: 0, "два")
        editor.press(#selector(NSResponder.cancelOperation(_:)))
        #expect(editor.textView.isBlockSelection)
        #expect(!editor.textView.formatBar.isShown, "Esc перевёл в режим блоков — панели нет")

        editor.textView.selectBlocks(0..<2)
        #expect(!editor.textView.formatBar.isShown)
    }

    @Test("Набор поверх выделения, уход фокуса и уход приложения в фон прячут панель")
    func hidesOnTypingFocusLossAndDeactivation() throws {
        let editor = try EditorFixture([.paragraph("один два")])
        editor.select(inBlock: 0, "два")
        editor.type("x")
        #expect(!editor.textView.formatBar.isShown, "Набор")

        editor.select(inBlock: 0, "один")
        #expect(editor.textView.formatBar.isShown)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(!editor.textView.formatBar.isShown, "Приложение ушло в фон")

        editor.select(inBlock: 0, "x")
        #expect(editor.textView.formatBar.isShown)
        editor.window.makeFirstResponder(nil)
        #expect(!editor.textView.formatBar.isShown, "Текст отдал фокус (щелчок мимо страницы)")
    }

    // MARK: Кнопки

    @Test("Кнопка ставит оформление на всё выделение и снимает его; нажатая подсвечена", arguments: [
        (FormatBarButton.bold, InlineStyle.bold), (.italic, .italic), (.underline, .underline), (.strikethrough, .strikethrough), (.code, .code),
    ])
    func buttonsToggleFormats(button: FormatBarButton, style: InlineStyle) throws {
        let editor = try EditorFixture([.paragraph("Привет, мир!"), .paragraph("ещё строка")])
        let start = editor.textLocation(ofBlock: 0) + 8
        editor.textView.setSelectedRange(NSRange(location: start, length: editor.textLocation(ofBlock: 1) + 3 - start))
        #expect(editor.textView.formatBar.state?.active.contains(button) == false)

        editor.step { editor.textView.formatBar.press(button) }
        #expect(editor.document.blocks[0].text.runs == [StyledRun(start: 8, length: 4, style: style)])
        #expect(editor.document.blocks[1].text.runs == [StyledRun(start: 0, length: 3, style: style)])
        #expect(editor.textView.formatBar.isShown, "Панель остаётся после нажатия, как в Notion")
        #expect(editor.textView.formatBar.state?.active.contains(button) == true)

        editor.step { editor.textView.formatBar.press(button) }
        #expect(editor.document.blocks.allSatisfy { $0.text.runs.isEmpty })
        #expect(editor.textView.formatBar.state?.active.contains(button) == false)
    }

    @Test("Подсвечено, только если оформление у всего выделения; ссылка — если всё выделение ссылка")
    func activeOnlyWhenWholeSelectionHasFormat() throws {
        let editor = try EditorFixture([.paragraph("один два")])
        editor.select(inBlock: 0, "два")
        editor.perform(.toggleInline(.bold))
        editor.step { editor.textView.setLink(URL(string: "https://kurilov.cloud")) }
        #expect(editor.textView.formatBar.state?.active == [.bold, .link])

        editor.select(inBlock: 0, "один два")
        #expect(editor.textView.formatBar.state?.active == [], "Жирное и ссылка — только часть выделения")
    }

    @Test("Кнопки по порядку: жирный, курсив, подчёркнутый, зачёркнутый, код, ссылка, цвет")
    func buttonOrder() {
        #expect(FormatBarButton.allCases == [.bold, .italic, .underline, .strikethrough, .code, .link, .color])
    }

    // MARK: Тип блока

    @Test("Список типов — те же, что в меню «/», текущий отмечен; выбор меняет тип всех выделенных блоков")
    func kindMenuChangesSelectedBlocks() throws {
        let editor = try EditorFixture([.paragraph("один"), .paragraph("два"), .paragraph("три")])
        let start = editor.textLocation(ofBlock: 0) + 1
        editor.textView.setSelectedRange(NSRange(location: start, length: editor.textLocation(ofBlock: 1) + 2 - start))
        let bar = editor.textView.formatBar

        bar.openKindMenu()
        #expect(bar.isKindMenuOpen)
        #expect(bar.kindMenuItems.map(\.title) == PopupMenuItem.blockKinds.map(\.title))
        #expect(bar.checkedKindItem?.title == "Текст")
        #expect(onScreenBars().isEmpty, "Список вышел на экран")

        editor.step { bar.chooseKind(.heading2) }
        #expect(editor.kinds == [.heading2, .heading2, .paragraph])
        #expect(!bar.isKindMenuOpen)
        #expect(bar.isShown && bar.state?.kindTitle == "Заголовок 2", "Выделение и панель остались")
        #expect(editor.textView.selectedRange().length > 0)
    }

    @Test("Esc закрывает только список типов; второй Esc — как без панели")
    func escapeClosesKindMenuFirst() throws {
        let editor = try EditorFixture([.paragraph("один два")])
        editor.select(inBlock: 0, "два")
        editor.textView.formatBar.openKindMenu()
        editor.press(#selector(NSResponder.cancelOperation(_:)))
        #expect(!editor.textView.formatBar.isKindMenuOpen)
        #expect(editor.textView.formatBar.isShown && !editor.textView.isBlockSelection)
    }

    @Test("«Разные типы» — в списке ничего не отмечено")
    func mixedKindsHaveNoCheckedItem() throws {
        let editor = try EditorFixture([.heading(1, "раз"), .paragraph("два")])
        editor.textView.setSelectedRange(NSRange(location: 1, length: editor.textLocation(ofBlock: 1) + 1))
        editor.textView.formatBar.openKindMenu()
        #expect(editor.textView.formatBar.checkedKindItem == nil)
    }

    // MARK: Место

    // Как у Notion: карточка под строкой выделения, левым краем у указателя мыши (и при выделении клавиатурой);
    // внизу не помещается — над строкой; у края окна прижимается к нему.
    static let line = NSRect(x: 300, y: 500, width: 120, height: 20)
    static let visible = NSRect(x: 100, y: 100, width: 800, height: 700)
    static let size = NSSize(width: Metrics.FormatBar.width, height: Metrics.FormatBar.height)

    @Test("Под строкой на selectionSpacing, левый край — у указателя со сдвигом pointerOffset")
    func placedBelowLineAtPointer() {
        let card = FormatBarPlacement.card(size: Self.size, line: Self.line, anchorX: 350, visible: Self.visible)
        #expect(card.size == Self.size)
        #expect(card.maxY == Self.line.minY - Metrics.FormatBar.selectionSpacing)
        #expect(card.minX == 350 + Metrics.FormatBar.pointerOffset)
    }

    @Test("Внизу нет места — над строкой")
    func flipsAboveWithoutRoomBelow() {
        let line = NSRect(x: 300, y: 150, width: 120, height: 20)
        let card = FormatBarPlacement.card(size: Self.size, line: line, anchorX: 350, visible: Self.visible)
        #expect(card.minY == line.maxY + Metrics.FormatBar.selectionSpacing)
    }

    @Test("У правого и левого края окна карточка прижимается к краю")
    func clampedToVisibleEdges() {
        let right = FormatBarPlacement.card(size: Self.size, line: Self.line, anchorX: 890, visible: Self.visible)
        #expect(right.maxX == Self.visible.maxX)
        let left = FormatBarPlacement.card(size: Self.size, line: Self.line, anchorX: 20, visible: Self.visible)
        #expect(left.minX == Self.visible.minX)
    }

    // Список типов — как у Notion (сверено 18.10.2026): сбоку от карточки, справа, заходит на неё на kindMenuOverlap
    // (до подсветки последней кнопки), серединой против строки типа; в пределах окна. Кнопок не закрывает.
    static let menuSize = NSSize(width: Metrics.PopupMenu.blockMenuWidth, height: 330)

    static func kindRow(of card: NSRect) -> NSRect {
        NSRect(x: card.minX + Metrics.FormatBar.horizontalPadding, y: card.maxY - Metrics.FormatBar.verticalPadding - Metrics.FormatBar.kindRowHeight,
               width: card.width - 2 * Metrics.FormatBar.horizontalPadding, height: Metrics.FormatBar.kindRowHeight)
    }

    @Test("Список типов — справа от карточки, серединой против строки типа")
    func kindMenuBesideCard() {
        let card = NSRect(origin: NSPoint(x: 300, y: 400), size: Self.size)
        let row = Self.kindRow(of: card)
        let menu = FormatBarPlacement.kindMenu(size: Self.menuSize, card: card, row: row, visible: Self.visible)
        #expect(menu.size == Self.menuSize)
        #expect(menu.minX == (card.maxX - Metrics.FormatBar.kindMenuOverlap).rounded(.up))
        #expect(menu.midY == row.midY)
    }

    @Test("Справа нет места — список слева от карточки")
    func kindMenuFlipsLeftWithoutRoom() {
        let card = NSRect(origin: NSPoint(x: 600, y: 400), size: Self.size)
        let menu = FormatBarPlacement.kindMenu(size: Self.menuSize, card: card, row: Self.kindRow(of: card), visible: Self.visible)
        #expect(menu.maxX == (card.minX + Metrics.FormatBar.kindMenuOverlap).rounded(.down))
    }

    @Test("У верха и низа окна список прижимается к краю")
    func kindMenuClampedVertically() {
        let high = NSRect(origin: NSPoint(x: 300, y: 700), size: Self.size)
        #expect(FormatBarPlacement.kindMenu(size: Self.menuSize, card: high, row: Self.kindRow(of: high), visible: Self.visible).maxY == Self.visible.maxY)
        let low = NSRect(origin: NSPoint(x: 300, y: 110), size: Self.size)
        #expect(FormatBarPlacement.kindMenu(size: Self.menuSize, card: low, row: Self.kindRow(of: low), visible: Self.visible).minY == Self.visible.minY)
    }

    @Test("Открытый список типов не закрывает строку типа и кнопки панели")
    func openKindMenuLeavesBarVisible() throws {
        let editor = try EditorFixture([.paragraph("первый абзац"), .paragraph("Выделяем слово в середине второго абзаца")])
        let view = editor.textView
        view.pointerLocation = { NSPoint(x: -10_000, y: -10_000) }
        editor.select(inBlock: 1, "слово")
        view.formatBar.openKindMenu()
        let card = try #require(view.formatBar.cardFrame)
        let menu = try #require(view.formatBar.kindMenuFrame)
        let overlap = Metrics.FormatBar.kindMenuOverlap
        let controls = NSRect(x: card.minX + overlap, y: card.minY, width: card.width - 2 * overlap, height: card.height)
        #expect(!menu.intersects(controls), "Список \(menu) закрывает панель \(card)")
    }

    @Test("Указатель над страницей — карточка у указателя, под строкой выделения рядом с ним")
    func editorPlacesCardAtPointer() throws {
        let editor = try EditorFixture([.paragraph("первый абзац"), .paragraph("Выделяем слово в середине второго абзаца")])
        let view = editor.textView
        let word = (view.string as NSString).range(of: "слово")
        let wordRect = view.firstRect(forCharacterRange: word, actualRange: nil)
        let pointer = NSPoint(x: wordRect.minX + 40, y: wordRect.midY)
        view.pointerLocation = { pointer }
        editor.select(inBlock: 1, "слово")
        let card = try #require(view.formatBar.cardFrame)
        #expect(card.minX == pointer.x + Metrics.FormatBar.pointerOffset, "Левый край \(card.minX), указатель \(pointer.x)")
        #expect(abs(card.maxY - (wordRect.minY - Metrics.FormatBar.selectionSpacing)) <= 1,
                "Верх карточки \(card.maxY), низ строки \(wordRect.minY)")
    }

    @Test("Указатель не над страницей — карточка у конца выделения")
    func editorPlacesCardAtSelectionEndWithoutPointer() throws {
        let editor = try EditorFixture([.paragraph("первый абзац"), .paragraph("Выделяем слово в середине второго абзаца")])
        let view = editor.textView
        view.pointerLocation = { NSPoint(x: -10_000, y: -10_000) }
        editor.select(inBlock: 1, "слово")
        let word = (view.string as NSString).range(of: "слово")
        let end = view.firstRect(forCharacterRange: NSRange(location: NSMaxRange(word) - 1, length: 1), actualRange: nil)
        let card = try #require(view.formatBar.cardFrame)
        #expect(abs(card.minX - (end.maxX + Metrics.FormatBar.pointerOffset)) <= 1, "Левый край \(card.minX), конец выделения \(end.maxX)")
    }

    @Test("Оформление при том же выделении не двигает панель, хоть указатель и стоит над ней (как в Notion)")
    func formattingKeepsCardInPlace() throws {
        let editor = try EditorFixture([.paragraph("первый абзац"), .paragraph("Выделяем слово в середине второго абзаца")])
        let view = editor.textView
        let wordRect = view.firstRect(forCharacterRange: (view.string as NSString).range(of: "слово"), actualRange: nil)
        var pointer = NSPoint(x: wordRect.minX + 40, y: wordRect.midY)
        view.pointerLocation = { pointer }
        editor.select(inBlock: 1, "слово")
        let placed = try #require(view.formatBar.cardFrame)

        pointer = NSPoint(x: placed.midX, y: placed.midY)
        editor.step { view.formatBar.press(.bold) }
        #expect(view.formatBar.cardFrame == placed, "После кнопки «Жирный»: \(String(describing: view.formatBar.cardFrame)), было \(placed)")
        editor.perform(.toggleInline(.underline))
        #expect(view.formatBar.cardFrame == placed, "После ⌘U: \(String(describing: view.formatBar.cardFrame)), было \(placed)")
    }

    @Test("Новое выделение ставит панель заново у указателя")
    func newSelectionPlacesCardAgain() throws {
        let editor = try EditorFixture([.paragraph("первый абзац"), .paragraph("Выделяем слово в середине второго абзаца")])
        let view = editor.textView
        var pointer = NSPoint(x: -10_000, y: -10_000)
        view.pointerLocation = { pointer }
        editor.select(inBlock: 1, "слово")
        let placed = try #require(view.formatBar.cardFrame)

        let middle = view.firstRect(forCharacterRange: (view.string as NSString).range(of: "середине"), actualRange: nil)
        pointer = NSPoint(x: middle.minX + 10, y: middle.midY)
        editor.select(inBlock: 1, "середине")
        let card = try #require(view.formatBar.cardFrame)
        #expect(card != placed)
        #expect(card.minX == pointer.x + Metrics.FormatBar.pointerOffset, "Левый край \(card.minX), указатель \(pointer.x)")
    }

    // MARK: Вид

    static func bar(_ state: FormatBarState) -> FormatBarView {
        let view = FormatBarView()
        view.state = state
        let margin = FormatBarWindow.shadowMargin
        view.frame = NSRect(x: 0, y: 0, width: Metrics.FormatBar.width + 2 * margin, height: Metrics.FormatBar.height + 2 * margin)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test("Размер карточки: ширина 7 кнопок по 36 (шесть как у Notion и цвет) и поля 6, строка типа 32, разделитель, ряд кнопок 31")
    func cardSize() {
        #expect(Metrics.FormatBar.width == 264)
        let height: CGFloat = 6 + 32 + 6 + 31 + 6
        #expect(Metrics.FormatBar.height == height, "Высота \(Metrics.FormatBar.height)")
    }

    @Test("Карточка видна на странице, разделитель цвета popupDivider под строкой типа", arguments: Self.themes)
    func cardAndDivider(theme: NSAppearance.Name) throws {
        let view = Self.bar(FormatBarState(kind: .paragraph, active: []))
        let pixels = try ViewPixels(view, appearance: theme)
        let page = Palette.pageBackground.resolved(in: theme)
        let margin = FormatBarWindow.shadowMargin
        let card = NSRect(x: margin, y: margin, width: Metrics.FormatBar.width, height: Metrics.FormatBar.height)
        for edge in [NSPoint(x: card.minX - 0.5, y: card.midY), NSPoint(x: card.maxX + 0.5, y: card.midY)] {
            #expect(colorDistance(pixels.color(at: edge, over: page), page) >= 0.05, "\(theme.rawValue): край карточки сливается со страницей")
        }
        // У Notion линия ≈ 40,5 ниже верха карточки, с 16 от краёв.
        let lineY = card.minY + Metrics.FormatBar.verticalPadding + Metrics.FormatBar.kindRowHeight + Metrics.FormatBar.dividerOffset
            + Metrics.FormatBar.dividerWidth / 2
        #expect(abs(lineY - card.minY - 40.5) <= 1.2)
        let divider = pixels.color(at: NSPoint(x: card.midX, y: lineY), over: page)
        #expect(colorDistance(divider, Palette.popupDivider.resolved(in: theme)) <= 0.04, "\(theme.rawValue): разделитель \(divider)")
        let beforeInset = pixels.color(at: NSPoint(x: card.minX + Metrics.FormatBar.dividerInset - 2, y: lineY), over: page)
        #expect(colorDistance(beforeInset, Palette.popupMenuBackground.resolved(in: theme)) <= 0.02, "Разделитель не доходит до края карточки")
    }

    /// Рисунок кнопки `index` в ряду значков.
    static func buttonInk(_ index: Int, in view: FormatBarView, pixels: ViewPixels) -> NSRect? {
        let margin = FormatBarWindow.shadowMargin
        let rowTop = margin + Metrics.FormatBar.verticalPadding + Metrics.FormatBar.kindRowHeight + Metrics.FormatBar.dividerBandHeight
        let cell = NSRect(x: margin + Metrics.FormatBar.horizontalPadding + CGFloat(index) * Metrics.FormatBar.buttonWidth, y: rowTop,
                          width: Metrics.FormatBar.buttonWidth, height: Metrics.FormatBar.buttonRowHeight)
        return pixels.inkBounds(in: cell.insetBy(dx: 2, dy: 2), over: Palette.popupMenuBackground.resolved(in: .aqua))
    }

    @Test("Значки кнопок по центру своих мест шириной 36 (у Notion первый — в 24 от края), размером как у Notion")
    func buttonIcons() throws {
        let view = Self.bar(FormatBarState(kind: .paragraph, active: []))
        let pixels = try ViewPixels(view, appearance: .aqua)
        let margin = FormatBarWindow.shadowMargin
        let rowMid = margin + Metrics.FormatBar.verticalPadding + Metrics.FormatBar.kindRowHeight + Metrics.FormatBar.dividerBandHeight
            + Metrics.FormatBar.buttonRowHeight / 2
        #expect(abs(rowMid - margin - 59.4) <= 1.2, "Середина ряда кнопок \(rowMid - margin), у Notion 59,4")
        for (index, button) in FormatBarButton.allCases.enumerated() {
            let ink = try #require(Self.buttonInk(index, in: view, pixels: pixels), "\(button): значка нет")
            let center = margin + 24 + CGFloat(index) * 36
            #expect(abs(ink.midX - center) <= 1.5, "\(button): значок в \(ink.midX - margin), место в \(center - margin)")
            #expect(abs(ink.midY - rowMid) <= 2, "\(button): значок не по середине ряда")
            // У Notion: «B» ≈ 11 высотой, «</>» ≈ 17,5 × 12,7, ссылка ≈ 15 × 15; сглаживание краёв — до 0,5 с боков.
            #expect(ink.height >= 8 && ink.height <= 15.5, "\(button): значок \(ink.size)")
            #expect(ink.width <= 19, "\(button): значок \(ink.size)")
        }
    }

    @Test("Нажатая кнопка — значок синий, как у Notion; ненажатая — цвета текста", arguments: Self.themes)
    func activeButtonIsBlue(theme: NSAppearance.Name) throws {
        let view = Self.bar(FormatBarState(kind: .paragraph, active: [.bold]))
        let pixels = try ViewPixels(view, appearance: theme)
        let bold = try #require(Self.buttonInk(0, in: view, pixels: pixels))
        let italic = try #require(Self.buttonInk(1, in: view, pixels: pixels))
        let blue = try #require(pixels.strongestInkColor(in: bold, over: Palette.popupMenuBackground.resolved(in: theme)))
        #expect(colorDistance(blue, Palette.formatBarActiveIcon.resolved(in: theme)) <= 0.12, "\(theme.rawValue): нажатая \(blue)")
        let plain = try #require(pixels.strongestInkColor(in: italic, over: Palette.popupMenuBackground.resolved(in: theme)))
        #expect(colorDistance(plain, Palette.textPrimary.resolved(in: theme)) <= 0.15, "\(theme.rawValue): ненажатая \(plain)")
    }

    @Test("Строка типа: значок по центру в 18 от края, название с 42, справа серая стрелка в 23 от края", arguments: ["Текст", "Разные типы"])
    func kindRow(title: String) throws {
        let state = FormatBarState(kind: title == "Текст" ? .paragraph : nil, active: [])
        #expect(state.kindTitle == title)
        let view = Self.bar(state)
        let pixels = try ViewPixels(view, appearance: .aqua)
        let margin = FormatBarWindow.shadowMargin
        let background = Palette.popupMenuBackground.resolved(in: .aqua)
        let row = NSRect(x: margin + 4, y: margin + Metrics.FormatBar.verticalPadding, width: Metrics.FormatBar.width - 8, height: Metrics.FormatBar.kindRowHeight)
        let icon = try #require(pixels.inkBounds(in: NSRect(x: row.minX, y: row.minY, width: 26, height: row.height), over: background))
        #expect(abs(icon.midX - margin - 18) <= 1.5, "Значок в \(icon.midX - margin)")
        #expect(abs(icon.midY - margin - 22) <= 2, "Середина строки типа \(icon.midY - margin), у Notion 22")
        let text = try #require(pixels.inkBounds(in: NSRect(x: margin + 38, y: row.minY, width: 140, height: row.height), over: background))
        #expect(abs(text.minX - margin - 42) <= 1.5, "Название с \(text.minX - margin)")
        let chevron = try #require(pixels.inkBounds(in: NSRect(x: row.maxX - 30, y: row.minY, width: 30, height: row.height), over: background))
        #expect(abs(margin + Metrics.FormatBar.width - chevron.midX - 23) <= 1.5, "Стрелка в \(margin + Metrics.FormatBar.width - chevron.midX) от края")
        let color = try #require(pixels.strongestInkColor(in: chevron, over: background))
        #expect(colorDistance(color, Palette.textSecondary.resolved(in: .aqua)) <= 0.15, "Стрелка \(color)")
    }

    @Test("В списке типов текущий отмечен галочкой справа")
    func kindMenuCheckmark() throws {
        let view = PopupMenuView(style: .kindPicker)
        view.setItems(PopupMenuItem.blockKinds)
        view.checkedItem = PopupMenuItem.blockKinds[2]
        let margin = PopupMenuWindow.shadowMargin
        let size = view.fittingMenuSize
        view.frame = NSRect(x: 0, y: 0, width: size.width + 2 * margin, height: size.height + 2 * margin)
        view.layoutSubtreeIfNeeded()
        let pixels = try ViewPixels(view, appearance: .aqua)
        let rows = view.subviews.compactMap { $0 as? PopupMenuRowView }
        for (index, row) in rows.enumerated() {
            let right = NSRect(x: row.frame.maxX - 30, y: row.frame.minY + 2, width: 30, height: row.frame.height - 4)
            let ink = pixels.inkBounds(in: right, over: Palette.popupMenuBackground.resolved(in: .aqua))
            #expect((ink != nil) == (index == 2), "\(row.item.title): галочка \(ink == nil ? "нет" : "есть")")
        }
    }
}
