import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Переключатель, цитата, выноска, разделитель (US1; contracts/blocks-and-keys.md, «Быстрые символы», «Вложенность»).
@MainActor
@Suite("Структурные блоки")
struct StructuralBlockTests {
    typealias Spec = EditorFixture.Spec

    nonisolated static func toggle(_ text: String, indent: Int = 0) -> Spec { Spec(kind: .toggle, text: text, indent: indent) }
    nonisolated static func quote(_ text: String, indent: Int = 0) -> Spec { Spec(kind: .quote, text: text, indent: indent) }
    nonisolated static func callout(_ text: String, indent: Int = 0) -> Spec { Spec(kind: .callout, text: text, indent: indent) }
    nonisolated static func child(_ text: String, indent: Int = 1) -> Spec { Spec(kind: .paragraph, text: text, indent: indent) }

    // MARK: Создание

    @Test("Быстрые символы: «> » — переключатель, «\" » — цитата; символы в текст не попадают; ⌘Z возвращает их",
          arguments: [(">", BlockKind.toggle), ("\"", .quote)])
    func shortcuts(prefix: String, kind: BlockKind) throws {
        let editor = try EditorFixture([.paragraph()])
        editor.placeCaret(inBlock: 0)
        editor.type(prefix + " ")
        #expect(editor.kinds == [kind])
        #expect(editor.texts == [""])

        editor.undo()
        #expect(editor.kinds == [.paragraph])
        #expect(editor.texts == [prefix])
        editor.redo()
        #expect(editor.kinds == [kind])
        editor.type("текст")
        #expect(editor.texts == ["текст"])
    }

    @Test("«---» сразу после третьего «-» — разделитель, курсор в новый абзац под ним; ⌘Z — шаг назад")
    func dividerShortcut() throws {
        let editor = try EditorFixture([.paragraph(), .paragraph("ниже")])
        editor.placeCaret(inBlock: 0)
        editor.type("---")
        #expect(editor.kinds == [.divider, .paragraph, .paragraph])
        #expect(editor.texts == ["", "", "ниже"])
        let caret = editor.textView.selectedRange()
        #expect(caret == NSRange(location: editor.textLocation(ofBlock: 1), length: 0), "курсор — в новом абзаце под разделителем")
        editor.type("а")
        #expect(editor.texts == ["", "а", "ниже"])

        editor.undo()
        #expect(editor.texts == ["", "", "ниже"])
        editor.undo()
        #expect(editor.kinds == [.paragraph, .paragraph], "⌘Z шага «третий -» возвращает абзац «--»")
        #expect(editor.texts == ["--", "ниже"])
    }

    @Test("«---» посреди текста или в заголовке разделителем не становится")
    func dividerOnlyInEmptyParagraph() throws {
        let editor = try EditorFixture([.paragraph("а"), .heading(1, "")])
        editor.placeCaret(inBlock: 0, at: nil)
        editor.type("---")
        editor.placeCaret(inBlock: 1)
        editor.type("---")
        #expect(editor.kinds == [.paragraph, .heading1])
        #expect(editor.texts == ["а---", "---"])
    }

    @Test("Меню «/» находит новые блоки по русским и английским словам")
    func slashSearch() {
        func kinds(_ query: String) -> [PopupMenuItem.Action] { PopupMenuItem.slashItems(matching: query).map(\.action) }
        #expect(kinds("выноска") == [.setKind(.callout)])
        #expect(kinds("callout") == [.setKind(.callout)])
        #expect(kinds("toggle") == [.setKind(.toggle)])
        #expect(kinds("переключатель") == [.setKind(.toggle)])
        #expect(kinds("quote") == [.setKind(.quote)])
        #expect(kinds("цитата") == [.setKind(.quote)])
        #expect(kinds("divider") == [.setKind(.divider)])
        #expect(kinds("линия") == [.setKind(.divider)])
        #expect(kinds("раскрыв") == [.setKind(.toggle)])
    }

    @Test("«/» → «Выноска»: иконка 💡 и серый фон по умолчанию; запись в базе такая же")
    func calloutFromSlashMenu() throws {
        let editor = try EditorFixture([.paragraph("совет")])
        editor.placeCaret(inBlock: 0, at: nil)
        editor.type(" /выноска")
        #expect(editor.textView.popups.visibleItems.map(\.action) == [.setKind(.callout)])
        editor.press(#selector(NSResponder.insertNewline(_:)))

        #expect(editor.kinds == [.callout])
        #expect(editor.texts == ["совет "])
        let callout = editor.document.blocks[0]
        #expect(callout.props.icon == "💡")
        #expect(callout.color == BlockColor(background: .gray))
        let saved = try editor.savedBlocks()
        #expect(saved[0].props.icon == "💡")
        #expect(saved[0].color.background == .gray)

        editor.undo()
        #expect(editor.kinds == [.paragraph])
        #expect(editor.document.blocks[0].color.isNone, "⌘Z возвращает и прежний вид блока")
    }

    @Test("«/» → «Разделитель» в абзаце с текстом: разделитель ниже, текст на месте, курсор — в абзаце под ним")
    func dividerFromSlashMenuKeepsText() throws {
        let editor = try EditorFixture([.paragraph("текст")])
        editor.placeCaret(inBlock: 0, at: nil)
        editor.type(" /divider")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(editor.kinds == [.paragraph, .divider, .paragraph])
        #expect(editor.texts == ["текст ", "", ""])
        #expect(editor.textView.selectedRange().location == editor.textLocation(ofBlock: 2))
        editor.undo()
        #expect(editor.kinds == [.paragraph])
    }

    // MARK: Вложенность

    @Test("Tab вкладывает под переключатель, выноску, цитату; под абзац и заголовок — нет",
          arguments: [(toggle("Р"), 1), (callout("Р"), 1), (quote("Р"), 1), (Spec.paragraph("Р"), 0), (Spec.heading(2, "Р"), 0)])
    func tabUnderContainers(parent: Spec, expected: Int) throws {
        let editor = try EditorFixture([parent, .paragraph("ребёнок")])
        editor.placeCaret(inBlock: 1, at: 2)
        editor.press(#selector(NSResponder.insertTab(_:)))
        #expect(editor.indents == [0, expected])
        #expect(editor.texts[1] == "ребёнок")
        if expected > 0 {
            editor.undo()
            #expect(editor.indents == [0, 0])
        }
    }

    @Test("Заголовок вкладывается только внутрь переключателя, выноски, цитаты",
          arguments: [(toggle("Р"), 1), (callout("Р"), 1), (quote("Р"), 1), (Spec.bullet("Р"), 0), (Spec.checkbox("Р"), 0)])
    func headingNesting(parent: Spec, expected: Int) throws {
        let editor = try EditorFixture([parent, .heading(2, "Заголовок")])
        editor.placeCaret(inBlock: 1)
        editor.press(#selector(NSResponder.insertTab(_:)))
        #expect(editor.indents == [0, expected])
        let saved = try editor.savedBlocks()
        #expect(saved.map(\.indent) == [0, expected], "вложенный заголовок записывается")
    }

    @Test("Смена типа на заголовок внутри переключателя оставляет вложенность, под пунктом — убирает")
    func headingKindKeepsNestingInContainer() throws {
        let editor = try EditorFixture([Self.toggle("Р"), Self.child("внутри"), .bullet("пункт"), .bullet("под пунктом", indent: 1)])
        editor.placeCaret(inBlock: 1)
        editor.perform(.setKind(.heading3))
        editor.placeCaret(inBlock: 3)
        editor.perform(.setKind(.heading3))
        #expect(editor.kinds == [.toggle, .heading3, .bulletItem, .heading3])
        #expect(editor.indents == [0, 1, 0, 0])
    }

    @Test("Enter в конце раскрытого переключателя — новый блок первым ребёнком")
    func enterInExpandedToggle() throws {
        let editor = try EditorFixture([Self.toggle("Р"), Self.child("старший"), .paragraph("ниже")])
        editor.placeCaret(inBlock: 0, at: nil)
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(editor.kinds == [.toggle, .paragraph, .paragraph, .paragraph])
        #expect(editor.texts == ["Р", "", "старший", "ниже"])
        #expect(editor.indents == [0, 1, 1, 0])
        #expect(editor.textView.selectedRange().location == editor.textLocation(ofBlock: 1))
        editor.undo()
        #expect(editor.texts == ["Р", "старший", "ниже"])
        #expect(editor.indents == [0, 1, 0])
    }

    @Test("Enter в конце выноски без детей — первый ребёнок")
    func enterInCallout() throws {
        let editor = try EditorFixture([Self.callout("Совет"), .paragraph("ниже")])
        editor.placeCaret(inBlock: 0, at: nil)
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(editor.kinds == [.callout, .paragraph, .paragraph])
        #expect(editor.indents == [0, 1, 0])
    }

    @Test("Enter в конце свёрнутого переключателя — новый блок после всех его детей")
    func enterInCollapsedToggle() throws {
        let editor = try EditorFixture([Self.toggle("Р"), Self.child("а"), Self.child("б", indent: 2), .paragraph("ниже")])
        editor.textView.setCollapsed(true, ofBlock: editor.document.blocks[0].id)
        editor.placeCaret(inBlock: 0, at: nil)
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(editor.texts == ["Р", "а", "б", "", "ниже"])
        #expect(editor.indents == [0, 1, 2, 0, 0])
        #expect(editor.kinds[3] == .toggle, "как список: следующий переключатель")
        #expect(editor.textView.selectedRange().location == editor.textLocation(ofBlock: 3))
        editor.undo()
        #expect(editor.texts == ["Р", "а", "б", "ниже"])
    }

    @Test("Enter в пустом ребёнке — выход на уровень выше")
    func enterInEmptyChildOutdents() throws {
        let editor = try EditorFixture([Self.toggle("Р"), Self.child("а"), Self.child("")])
        editor.placeCaret(inBlock: 2)
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(editor.indents == [0, 1, 0])
        #expect(editor.texts == ["Р", "а", ""])
        #expect(editor.kinds.count == 3, "новый блок не создаётся")
        editor.undo()
        #expect(editor.indents == [0, 1, 1])
    }

    @Test("⌫ в начале переключателя, цитаты, выноски — абзац; дети поднимаются на уровень",
          arguments: [BlockKind.toggle, .quote, .callout])
    func backspaceTurnsIntoParagraph(kind: BlockKind) throws {
        let editor = try EditorFixture([.paragraph("выше"), Spec(kind: kind, text: "Р"), Self.child("а"), Self.child("б", indent: 2),
                                        .paragraph("ниже")])
        editor.placeCaret(inBlock: 1)
        editor.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(editor.kinds == [.paragraph, .paragraph, .paragraph, .paragraph, .paragraph])
        #expect(editor.texts == ["выше", "Р", "а", "б", "ниже"])
        #expect(editor.indents == [0, 0, 0, 1, 0])
        #expect(editor.document.blocks[1].color.isNone, "у абзаца нет серого фона выноски")
        editor.undo()
        #expect(editor.kinds[1] == kind)
        #expect(editor.indents == [0, 0, 1, 2, 0])
    }

    @Test("Вложенные под переключателем едут с ним при перестановке")
    func childrenMoveWithToggle() throws {
        let editor = try EditorFixture([.paragraph("А"), Self.toggle("Р"), Self.child("а"), .paragraph("Б")])
        editor.placeCaret(inBlock: 1)
        editor.perform(.moveBlocksUp)
        #expect(editor.texts == ["Р", "а", "А", "Б"])
        editor.undo()
        #expect(editor.texts == ["А", "Р", "а", "Б"])
    }

    @Test("Всё переживает запись: типы, вложенность, иконка выноски")
    func savedStructure() throws {
        let editor = try EditorFixture([.paragraph()])
        editor.placeCaret(inBlock: 0)
        editor.type("> Р")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        editor.type("внутри")
        let saved = try editor.savedBlocks()
        #expect(saved.map(\.kind) == [.toggle, .paragraph])
        #expect(saved.map(\.indent) == [0, 1])
        #expect(saved.map(\.text.string) == ["Р", "внутри"])
    }

    // MARK: Вид вложенных (сверено с Notion 19.10.2026)

    /// Начало текста блока на странице.
    private static func textStart(_ editor: EditorFixture, _ index: Int) throws -> CGFloat {
        try #require(editor.textView.markerLine(ofBlockAt: index)).caretX
    }

    @Test("Дети цитаты и выноски — вровень с текстом родителя, как у Notion; маркер пункта — там же")
    func childrenAlignWithParentText() throws {
        let editor = try EditorFixture([Self.quote("Цитата"), Self.child("в цитате"), Self.callout("Выноска"), Self.child("в выноске"),
                                        .bullet("пункт в выноске", indent: 1), Self.toggle("Переключатель"), Self.child("в переключателе")])
        #expect(abs(try Self.textStart(editor, 1) - Self.textStart(editor, 0)) < 0.5)
        #expect(abs(try Self.textStart(editor, 3) - Self.textStart(editor, 2)) < 0.5)
        let bullet = try #require(editor.textView.markerLine(ofBlockAt: 4))
        #expect(abs(bullet.markerColumn.minX - (try Self.textStart(editor, 2))) < 0.5,
                "колонка маркера пункта начинается у текста выноски")
        // У переключателя дети — на шаге вложенности, как пункты списка 001.
        #expect(try Self.textStart(editor, 6) > Self.textStart(editor, 5))
        #expect(editor.indents == [0, 1, 0, 1, 1, 0, 1], "записанная вложенность не меняется")
    }

    @Test("Нижнее поле выноски — у её последнего видимого ребёнка, у самой выноски с детьми — обычный отступ")
    func calloutBottomPaddingAfterLastChild() throws {
        let editor = try EditorFixture([Self.callout("Выноска"), Self.child("первый"), Self.child("последний"), .paragraph("после")])
        func spacingAfter(_ index: Int) -> CGFloat {
            let location = editor.textLocation(ofBlock: index)
            return (editor.textView.textStorage?.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?
                .paragraphSpacing ?? -1
        }
        let base = spacingAfter(3)
        #expect(spacingAfter(0) == base)
        #expect(spacingAfter(1) == base)
        #expect(spacingAfter(2) == base + Metrics.Callout.verticalPadding)
        // Набор в последнем ребёнке не теряет поле.
        editor.placeCaret(inBlock: 2, at: nil)
        editor.type("!")
        #expect(spacingAfter(2) == base + Metrics.Callout.verticalPadding)
    }

    @Test("Слишком глубокий блок (после слияния) показывается на допустимой глубине, запись не меняется")
    func overDeepBlockIsClampedOnScreen() throws {
        let reopened = try EditorFixture([.paragraph("А"), Spec(kind: .paragraph, text: "слишком глубоко", indent: 2), .bullet("пункт"),
                                          Spec(kind: .heading2, text: "Заголовок", indent: 1), .bullet("под пунктом", indent: 1)])
        #expect(abs(try Self.textStart(reopened, 1) - Self.textStart(reopened, 0)) < 0.5, "абзац под абзацем — на его глубине")
        #expect(abs(try Self.textStart(reopened, 3) - Self.textStart(reopened, 0)) < 0.5, "заголовок под пунктом — на глубине 0")
        #expect(try Self.textStart(reopened, 4) > Self.textStart(reopened, 3))
        #expect(reopened.indents == [0, 2, 0, 1, 1])
        #expect(try reopened.savedBlocks().map(\.indent) == [0, 2, 0, 1, 1])
    }

    // MARK: Разделитель

    @Test("Курсор на разделителе не стоит: стрелки перешагивают")
    func caretSkipsDivider() throws {
        let editor = try EditorFixture([.paragraph("до"), Spec(kind: .divider), .paragraph("после")])
        editor.placeCaret(inBlock: 0, at: nil)
        editor.press(#selector(NSResponder.moveRight(_:)))
        #expect(editor.textView.selectedRange().location == editor.textLocation(ofBlock: 2))
        editor.press(#selector(NSResponder.moveLeft(_:)))
        #expect(editor.textView.selectedRange().location == editor.textLocation(ofBlock: 0) + 2)
    }
}
