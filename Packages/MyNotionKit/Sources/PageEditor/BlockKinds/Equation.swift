import AppKit
import MathRendering
import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    /// Формула-блок (US4, FR-105): запись LaTeX в `text` блока, по центру колонки; щелчок — окно правки.
    static let equation = BlockKindDescriptor(
        kind: .equation,
        menuItem: PopupMenuItem(title: "Формула", icon: .symbol("function"), keywords: ["equation", "math", "latex", "формула", "$$"],
                                action: .setKind(.equation)),
        markdownShortcuts: ["$$"],
        gallerySamples: [
            BlockGallerySample(id: "equation-blocks", summary: "Дробь, матрица, cases, пустая и неверная формула, формула в строке",
                               blocks: [
                                   .init(.paragraph, "Абзац над формулой"),
                                   .init(.equation, "x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}"),
                                   .init(.equation, "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}"),
                                   .init(.equation, "f(x) = \\begin{cases} 1 & x > 0 \\\\ 0 & x \\le 0 \\end{cases}"),
                                   .init(.equation),
                                   .init(.equation, "\\frac{1}{"),
                                   .init(.paragraph, "Абзац под формулами"),
                               ], narrowToo: true),
        ],
        // Богатая страница (quickstart.md): 10 формул.
        richPageBlocks: (1...10).map { RichBlockSpec(.equation, "\\sum_{i=1}^{\($0)} i^2 = \\frac{n(n+1)(2n+1)}{6}") }
    )
}

/// Поля формулы-блока вокруг картинки (сверено с Notion, contracts/blocks-and-keys.md).
enum EquationBlockStyle {
    static let fontSize: CGFloat = 17
    static let verticalPadding: CGFloat = 8
    static let emptyHeight: CGFloat = 24
    static var placeholderFont: NSFont { .systemFont(ofSize: 14) }
}

/// Фабрика вида формулы-блока.
@MainActor
final class EquationBlockViewFactory: BlockViewFactory {
    func makeView(for block: Block, context: BlockViewContext) -> NSView? {
        EquationBlockView(block: block, page: context.textView)
    }

    func height(for block: Block, width: CGFloat) -> CGFloat? {
        let result = FormulaImageCache.shared.render(block.text.string, fontSize: EquationBlockStyle.fontSize, theme: .light)
        let content: CGFloat = if case .rendered(let formula) = result { formula.image.size.height } else { EquationBlockStyle.emptyHeight }
        return content + 2 * EquationBlockStyle.verticalPadding
    }
}

/// Формула по центру колонки; пустая — серое «Новая формула», ошибка — красное «Неверная формула». Щелчок — окно правки.
@MainActor
final class EquationBlockView: NSView, BlockFieldsView {
    let blockId: UUID
    private(set) var latex: String
    weak var page: PageTextView?
    private(set) var formulaImage: NSImage?
    /// Надпись вместо формулы: пустая или неверная запись.
    private(set) var message: String?
    private var isInvalid = false

    init(block: Block, page: PageTextView?) {
        blockId = block.id
        latex = block.text.string
        self.page = page
        super.init(frame: NSRect(x: 0, y: 0, width: 720, height: 40))
        setAccessibilityIdentifier("equation-block")
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    func update(_ block: Block) {
        guard block.text.string != latex else { return }
        latex = block.text.string
        render()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    private func render() {
        switch FormulaImageCache.shared.render(latex, fontSize: EquationBlockStyle.fontSize, theme: FormulaTheme(effectiveAppearance)) {
        case .empty:
            formulaImage = nil
            message = FormulaImageCache.emptyFormulaText
            isInvalid = false
        case .invalid:
            formulaImage = nil
            message = FormulaImageCache.invalidFormulaText
            isInvalid = true
        case .rendered(let formula):
            formulaImage = formula.image
            message = nil
        }
        setAccessibilityValue(latex)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let formulaImage {
            let size = formulaImage.size
            let origin = NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded())
            formulaImage.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                              respectFlipped: true, hints: nil)
            return
        }
        guard let message else { return }
        let text = NSAttributedString(string: message, attributes: [
            .font: EquationBlockStyle.placeholderFont,
            .foregroundColor: isInvalid ? Palette.destructiveText : Palette.textSecondary,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded()))
    }

    override func mouseDown(with event: NSEvent) {
        page?.openEquationEditor(forBlock: blockId)
    }
}

extension PageTextView {
    /// Блок `index` становится формулой (текст абзаца — запись), окно правки открыто.
    func insertEquation(at index: Int) {
        commitEdits()
        let block = document.blocks[index]
        var draft = BlockDraft(block)
        draft.kind = .equation
        draft.isChecked = false
        draft.adoptDefaults(of: .equation, from: block)
        changeBlocks(index..<index + 1, to: [draft], actionName: "Формула")
        openEquationEditor(forBlock: block.id)
    }

    /// Окно правки формулы-блока под ним.
    func openEquationEditor(forBlock id: UUID) {
        guard let index = document.index(ofBlock: id) else { return }
        commitEdits()
        selectBlocks(index..<index + 1)
        let anchor = rectOfCharacters(NSRange(location: mapper.paragraphStart(ofBlockAt: index), length: 1))
        equationEditor.open(.block(id), latex: document.blocks[index].text.string, below: anchor)
    }

    /// ⌃⇧E и «√x»: выделенный текст становится формулой в строке; без выделения — новая формула и окно правки.
    func insertInlineEquation() {
        commitEdits()
        let selection = selectedRange()
        guard let position = mapper.blockPosition(at: selection.location) else { return }
        let block = document.blocks[position.index]
        guard !block.kind.rendersAsAttachment, block.kind != .pageLink else { return }
        let blockEnd = selection.location - position.offset + block.pageTextLength
        let range = NSRange(location: selection.location, length: min(selection.length, blockEnd - selection.location))
        let latex = plainText(of: range)
        insertAtom(.equation(latex), in: range, blockAt: position.index)
        if latex.isEmpty { openEquationEditor(atCharacter: range.location) }
    }

    /// Окно правки формулы в строке у знака `index`.
    func openEquationEditor(atCharacter index: Int) {
        guard case .equation(let latex)? = atomAttachment(at: index)?.style, let position = mapper.blockPosition(at: index) else { return }
        equationEditor.open(.inline(blockId: document.blocks[position.index].id, location: position.offset), latex: latex,
                            below: rectOfCharacters(NSRange(location: index, length: 1)))
    }

    /// Готовая запись из окна правки: формула-блок — правкой блока, формула в строке — заменой её знака. Одно действие ⌘Z.
    func applyEquation(_ latex: String, to target: EquationTarget) {
        switch target {
        case .block(let id):
            guard let index = document.index(ofBlock: id), document.blocks[index].text.string != latex else { return }
            var draft = BlockDraft(document.blocks[index])
            draft.text = InlineText(latex)
            changeBlocks(index..<index + 1, to: [draft], actionName: "Формула")
        case .inline(let blockId, let offset):
            guard let index = document.index(ofBlock: blockId) else { return }
            let location = mapper.paragraphStart(ofBlockAt: index) + offset
            guard case .equation(let old)? = atomAttachment(at: location)?.style, old != latex else { return }
            insertAtom(.equation(latex), in: NSRange(location: location, length: 1), blockAt: index)
        }
    }

    /// Место знаков в координатах вида текста.
    func rectOfCharacters(_ range: NSRange) -> NSRect {
        guard let window else { return .zero }
        return convert(window.convertFromScreen(firstRect(forCharacterRange: range, actualRange: nil)), from: nil)
    }
}
