import AppKit
import NotesCore
import VisualStyle

/// Всё, что редактор знает о типе блока (plan.md, Structure Decision): строка меню «/», быстрые символы, вид строки,
/// маркер, подсказка пустого блока, рисователи, снимки галереи. Каждый тип — свой файл в `BlockKinds/`:
/// этап, вводящий тип, правит только его файл, а не общие `switch`.
struct BlockKindDescriptor: Sendable {
    let kind: BlockKind
    /// Строка меню «/» и «Превратить в»; `nil` — типа в меню нет.
    var menuItem: PopupMenuItem?
    /// Быстрые символы: набранные в начале блока с пробелом, меняют его тип. Первый показан справа в меню «/».
    var markdownShortcuts: [String] = []
    var textStyle: BlockTextStyle = .paragraph
    /// Что стоит в колонке маркера слева от текста.
    var marker: BlockMarker = .none
    /// Где начинается текст блока без колонки маркера: правее черты цитаты, иконки выноски.
    var leadingInset: CGFloat = 0
    /// Своя высота строки вместо высоты стиля текста (строка разделителя).
    var lineHeight: CGFloat?
    /// Свои отступы над и под абзацем блока вместо отступов стиля текста (поля выноски, строка разделителя).
    var topSpacing: CGFloat?
    var bottomSpacing: CGFloat?
    /// Подсказка пустого блока; у абзаца — только под курсором.
    var emptyHint: String?
    /// Enter в пустом блоке превращает его в абзац (пункты списков).
    var exitsOnEmptyEnter = false
    /// Новый блок после Enter — того же типа; иначе абзац.
    var continuesAfterSplit = false
    /// Подложка, черта, рамка — рисуются по абзацу блока (`BlockPainters/`).
    var painters: [any BlockPainter] = []
    /// Состояния галереи `--ui-gallery` для этого типа.
    var gallerySamples: [BlockGallerySample] = []
    /// Своя часть эталонной «богатой» страницы замеров (quickstart.md, `RichPageGenerator`).
    var richPageBlocks: [RichBlockSpec] = []

    init(kind: BlockKind, menuItem: PopupMenuItem? = nil, markdownShortcuts: [String] = [], textStyle: BlockTextStyle = .paragraph,
         marker: BlockMarker = .none, leadingInset: CGFloat = 0, lineHeight: CGFloat? = nil, topSpacing: CGFloat? = nil,
         bottomSpacing: CGFloat? = nil, emptyHint: String? = nil, exitsOnEmptyEnter: Bool = false, continuesAfterSplit: Bool = false,
         painters: [any BlockPainter] = [], gallerySamples: [BlockGallerySample] = [], richPageBlocks: [RichBlockSpec] = []) {
        self.kind = kind
        self.menuItem = menuItem
        self.markdownShortcuts = markdownShortcuts
        self.textStyle = textStyle
        self.marker = marker
        self.leadingInset = leadingInset
        self.lineHeight = lineHeight
        self.topSpacing = topSpacing
        self.bottomSpacing = bottomSpacing
        self.emptyHint = emptyHint
        self.exitsOnEmptyEnter = exitsOnEmptyEnter
        self.continuesAfterSplit = continuesAfterSplit
        self.painters = painters
        self.gallerySamples = gallerySamples
        self.richPageBlocks = richPageBlocks
    }

    /// Тип, который этап ещё не наполнил: ведёт себя как абзац без меню и быстрых символов.
    static func notYetBuilt(_ kind: BlockKind) -> BlockKindDescriptor {
        BlockKindDescriptor(kind: kind)
    }
}

/// Маркеры 001 в колонке слева от текста. Свои значки новых типов (треугольник переключателя) рисуют их рисователи.
enum BlockMarker: Sendable, Hashable {
    case none
    case bullet
    case number
    case checkbox
    case pageLink
    /// Колонка маркера есть, значок в ней рисует рисователь типа (треугольник переключателя).
    case painted
}

/// Слой рисователя: под текстом (подложка) или поверх него (черта, треугольник).
enum BlockPaintLayer: Sendable {
    case background
    case foreground
}

/// Рисует часть вида блока в его фрагменте раскладки (`BlockLayoutFragment`).
protocol BlockPainter: Sendable {
    var layer: BlockPaintLayer { get }
    /// Рисует ли что-то у этого блока: общие рисователи проверяют дёшево, до подготовки рисования.
    func applies(to block: Block) -> Bool
    @MainActor func paint(_ block: Block, in context: BlockPaintContext)
}

extension BlockPainter {
    func applies(to block: Block) -> Bool { true }
}

/// Где рисовать: абзац блока в координатах рисования фрагмента.
struct BlockPaintContext {
    /// Колонка страницы по высоте абзаца: от левого края колонки до правого.
    let paragraphRect: CGRect
    /// Первая строка абзаца (маркер, базовая линия), в координатах рисования.
    let firstLine: BlockLine?
    /// Последняя строка абзаца, в координатах рисования.
    let lastLine: BlockLine?
    let textView: PageTextView
}

/// Снимок галереи для типа блока: страница из этих блоков (plan.md, «Проверка интерфейса»).
public struct BlockGallerySample: Sendable, Hashable {
    public struct SampleBlock: Sendable, Hashable {
        public var kind: BlockKind
        public var text: InlineText
        public var indent: Int
        public var color: BlockColor
        public var props: BlockProps
        /// Переключатель свёрнут на этом Mac.
        public var isCollapsed: Bool

        public init(_ kind: BlockKind, _ text: String = "", indent: Int = 0, color: BlockColor = .none, props: BlockProps? = nil,
                    isCollapsed: Bool = false) {
            self.kind = kind
            self.text = InlineText(text)
            self.indent = indent
            self.color = color
            self.props = props ?? .defaults(for: kind)
            self.isCollapsed = isCollapsed
        }
    }

    /// Имя снимка в галерее, латиницей.
    public var id: String
    /// Что на снимке — для проверяющего.
    public var summary: String
    public var blocks: [SampleBlock]
    /// Снимать и в узком окне.
    public var narrowToo: Bool

    public init(id: String, summary: String, blocks: [SampleBlock], narrowToo: Bool = false) {
        self.id = id
        self.summary = summary
        self.blocks = blocks
        self.narrowToo = narrowToo
    }
}
