import NotesCore
import PageEditor

/// Что показать в окне на одном снимке галереи (флаг `--ui-gallery`, plan.md, «Проверка интерфейса»).
/// Приложение приводит окно в каждую сцену по очереди; `switch` по сцене там полный, поэтому новая сцена
/// без способа её снять не соберётся.
public enum GalleryScene: Hashable, Sendable {
    /// Страница «MyNotion — образец» сверху или прокрученная до конца (там блоки-подстраницы).
    case samplePage(scrolledToBottom: Bool)
    /// Страница одного типа блока: заполненный блок, пустой в середине и пустой в конце.
    case block(BlockKind, GalleryCaret)
    /// Страница из блоков образца типа 002 (`BlockKindDescriptor.gallerySamples`).
    case kindSample(BlockGallerySample)
    /// Окно «@» под курсором в образце упоминаний; `query` — набранное после «@» (US3).
    case mentionPicker(query: String)
    /// Календарик даты в образце упоминаний (US3).
    case datePicker
    /// Страница из одного пустого абзаца, курсор в нём.
    case emptyPage
    /// Страница без названия, курсор в названии.
    case untitledPage
    /// Списки и чекбоксы трёх уровней, отмеченные чекбоксы.
    case nestedLists
    /// Ручки «+ ⋮⋮» у блока под мышью.
    case blockHover(BlockKind)
    /// Меню «/» в пустом абзаце; `filter` — набранное после «/».
    case slashMenu(filter: String)
    /// Меню блока по щелчку на «⋮⋮»; `turnInto` — открыто подменю «Преобразовать в».
    case blockMenu(turnInto: Bool)
    /// Последний пустой блок страницы списка стал пунктом от «- »: маркер и подсказка там же, где у пункта выше.
    case bulletByShortcutAtEnd
    /// Пункт с вложенными тянут за «⋮⋮»: копия едет за мышью, линия показывает место сброса.
    case blockDragging
    /// Выделенный текст с жирным, курсивом и кодом.
    case formattedSelection
    /// Выделен текст двух пунктов нумерованного списка и абзаца под ними: полосы по тексту построчно.
    case selectionAcrossBlocks
    /// Те же блоки в режиме выделения блоков (Esc, «⋮⋮», протяжка с поля): прямоугольник на каждый блок.
    case blockSelection
    /// Панель форматирования над выделенным жирным словом; `kindMenu` — открыт список типов.
    case formatBar(kindMenu: Bool)
    /// Страница с цветным текстом, цветным фоном строки и цветными блоками (US2, FR-112).
    case colorsOnPage
    /// Окно цветов: `fromBlockMenu` — открыто пунктом «Цвет» меню блока, иначе кнопкой «A» панели форматирования.
    case colorMenu(fromBlockMenu: Bool)
    /// Блоки с переносами строк (Shift+Enter); курсор во второй строке пункта.
    case softLineBreaks
    /// Выделение через блоки с переносами строк: одна подложка на все строки.
    case selectionAcrossSoftBreaks
    /// Иконка страницы: «Добавить иконку» под мышью, окно выбора эмодзи, поиск в нём (FR-034).
    case pageIcon(GalleryPageIcon)
    /// Дерево четырёх уровней: ветка развёрнута или свёрнута.
    case sidebarTree(collapsed: Bool)
    /// Строка дерева под мышью: «⋯ +» справа; у длинного названия — обрезка перед ними.
    case sidebarRowHover(longTitle: Bool)
    /// Открыта вложенная страница: её строка выбрана.
    case sidebarSelectedRow
    /// Строка дерева в режиме переименования.
    case sidebarRenaming
    /// Боковая панель свёрнута шторкой: шторка у светофора над страницей.
    case sidebarHidden
    /// В поле поиска набрано слово: выдача под полем; `nothingFound` — слово, которого нет (FR-018).
    case search(nothingFound: Bool)
    case trash(GalleryTrash)
    /// Полоса «Изменения не сохранены…» над страницей.
    case saveErrorBanner
    /// Верхняя полоса с длинным путём страницы четвёртого уровня.
    case longBreadcrumb
    /// Верхняя полоса страницы справа: «•••» (003, этап 0; «☆» добавляет US2).
    case pageTopBar
    /// «☆» в верхней полосе (US2): страница в избранном (закрашенная «★») или нет (пустая).
    case favoriteStar(isFavorite: Bool)
    /// Разделы «Недавние» и «Избранное» над деревом (US2).
    case sidebarSections(GallerySidebarSections)
    /// Открытое меню «•••» страницы: поле «Найти действие…», пункты, подвал «Изменено…» (003, этап 0).
    case pageMenu
    /// Синхронизация между Mac (US5): значок, «Две версии», настройки подключения, уведомление.
    case sync(GallerySync)
    /// Импорт из Notion (US6): карточка хода, вопрос о повторе той же выгрузки, отчёт.
    case notionImport(GalleryNotionImport)
    /// Выгрузка в Markdown (FR-017): карточка хода, итог с «Показать в Finder», ошибка.
    case markdownExport(GalleryMarkdownExport)
}

public enum GalleryMarkdownExport: String, Hashable, Sendable, CaseIterable {
    case progress
    case done
    case failed
}

public enum GalleryNotionImport: String, Hashable, Sendable, CaseIterable {
    /// Карточка внизу окна: «Перенесено страниц: 420 из 1 000» и «Остановить».
    case progress
    /// Окно «Этот файл из Notion уже переносили».
    case repeatWarning
    /// Окно итога: сколько перенесено и что стало простым текстом.
    case report
}

public enum GallerySync: String, Hashable, Sendable, CaseIterable {
    /// Значок внизу панели: всё отправлено.
    case badgeReady
    /// Значок: идёт отправка.
    case badgeSending
    /// Значок: ошибка (нет связи).
    case badgeError
    /// Подробности ошибки по щелчку на значке.
    case badgeErrorDetails
    /// Блок в конфликте: оранжевая метка «Две версии».
    case conflictLabel
    /// Окно сравнения двух версий с выбором.
    case conflictComparison
    /// Настройки: синхронизация не включена — подключить кодом или токеном.
    case settingsDisconnected
    /// Настройки: «Добавить Mac» показал код с предупреждением, список устройств.
    case settingsJoinCode
    /// Уведомление внизу окна: страница вернулась из корзины.
    case noticeReturnedFromTrash
}

/// Где курсор на странице типа блока.
public enum GalleryCaret: String, Hashable, Sendable, CaseIterable {
    case none
    case inMiddle
    case atEnd
}

public enum GalleryPageIcon: String, Hashable, Sendable, CaseIterable {
    /// Мышь над шапкой страницы без иконки: серая «Добавить иконку» над названием.
    case addIconHover
    /// Окно выбора эмодзи под иконкой страницы.
    case picker
    /// В окне набрано «кот»: результаты без разделов, первый подсвечен.
    case pickerSearch
}

public enum GalleryTrash: String, Hashable, Sendable, CaseIterable {
    /// Строка «Корзина» внизу панели.
    case rowAtBottom
    /// Окно корзины с записями.
    case open
    /// Диалог «Удалить навсегда?».
    case confirmDeleteForever
    /// Окно пустой корзины. Очищает корзину, поэтому снимается последним.
    case openEmpty
}

public enum GalleryTheme: String, Hashable, Sendable, CaseIterable, Codable {
    case light
    case dark

    public var title: String { self == .light ? "светлая" : "тёмная" }
}

/// Состояния разделов «Недавние» и «Избранное» (US2).
public enum GallerySidebarSections: CaseIterable, Sendable {
    /// Пять недавних со строкой «Показать все» и избранное, у одной избранной раскрыты подстраницы.
    case recentAndFavorites
    /// «Избранное» свёрнуто щелчком по заголовку.
    case favoritesCollapsed
    /// Меню строки избранной страницы: «Убрать из избранного».
    case favoriteRowMenu
}

public struct GalleryWindowSize: Hashable, Sendable, Codable {
    public let width: Int
    public let height: Int

    public static let wide = GalleryWindowSize(width: 1440, height: 900)
    public static let narrow = GalleryWindowSize(width: 900, height: 700)

    public var name: String { "\(width)x\(height)" }
}

/// Состояние галереи: сцена, имя файла и описание для проверяющего.
public struct GalleryState: Hashable, Sendable {
    public let id: String
    public let scene: GalleryScene
    public let summary: String
    /// Раздел в index.html.
    public let section: String
    public let sizes: [GalleryWindowSize]

    init(_ id: String, _ scene: GalleryScene, _ summary: String, section: String, narrowToo: Bool = false) {
        self.id = id
        self.scene = scene
        self.summary = summary
        self.section = section
        sizes = narrowToo ? [.wide, .narrow] : [.wide]
    }
}

/// Один снимок: состояние в теме и размере окна.
public struct GalleryShot: Hashable, Sendable {
    public let state: GalleryState
    public let theme: GalleryTheme
    public let size: GalleryWindowSize

    public var fileName: String { "\(state.id)--\(size.name)--\(theme.rawValue).png" }
}

public enum GalleryCatalog {
    /// Все состояния по порядку съёмки.
    public static let states: [GalleryState] = pageStates + blockStates + kindSampleStates + inlineAtomStates + editingStates + sidebarStates
        + trashStates + importStates + exportStates + syncStates

    /// Окно «@» и календарик даты (US3, contracts/blocks-and-keys.md, «Упоминания», «Даты и напоминания»).
    static let inlineAtomStates: [GalleryState] = [
        GalleryState("mention-picker", .mentionPicker(query: ""), "Окно «@»: страницы и даты", section: "Блоки 002"),
        GalleryState("mention-picker-filtered", .mentionPicker(query: "план"), "Окно «@» с поиском «план»", section: "Блоки 002"),
        GalleryState("date-picker", .datePicker, "Календарик даты: месяц, время, «Напомнить», «Удалить»", section: "Блоки 002"),
    ]

    /// Снимки блоков 002 — из описателей типов: этап, вводящий тип, добавляет образец в описатель, а не сюда.
    static var kindSampleStates: [GalleryState] {
        BlockKinds.gallerySamples.map { sample in
            GalleryState("kind-\(sample.id)", .kindSample(sample), sample.summary, section: "Блоки 002", narrowToo: sample.narrowToo)
        }
    }

    /// Все снимки: каждое состояние в каждом размере, светлая и тёмная тема подряд.
    public static var shots: [GalleryShot] {
        states.flatMap { state in
            state.sizes.flatMap { size in GalleryTheme.allCases.map { GalleryShot(state: state, theme: $0, size: size) } }
        }
    }

    /// Типы блоков с текстом (у блока-подстраницы текста нет).
    public static let textBlockKinds: [BlockKind] = [.paragraph, .heading1, .heading2, .heading3, .bulletItem, .numberedItem, .checkbox]

    static func name(of kind: BlockKind) -> String {
        switch kind {
        case .paragraph: "абзац"
        case .heading1: "заголовок 1"
        case .heading2: "заголовок 2"
        case .heading3: "заголовок 3"
        case .bulletItem: "маркированный пункт"
        case .numberedItem: "нумерованный пункт"
        case .checkbox: "чекбокс"
        case .pageLink: "подстраница"
        case .toggle: "раскрывающийся список"
        case .quote: "цитата"
        case .callout: "выноска"
        case .divider: "разделитель"
        case .code: "код"
        case .equation: "формула"
        case .tableOfContents: "оглавление"
        case .image: "картинка"
        case .file: "файл"
        case .video: "видео"
        case .bookmark: "закладка"
        case .table: "таблица"
        case .tableRow: "строка таблицы"
        case .tableColumn: "столбец таблицы"
        case .tableCell: "ячейка таблицы"
        case .columnList: "колонки"
        case .column: "колонка"
        }
    }

    private static let pageStates: [GalleryState] = [
        GalleryState("sample-top", .samplePage(scrolledToBottom: false),
                     "«MyNotion — образец» сверху: оформление текста, заголовки, списки", section: "Страница", narrowToo: true),
        GalleryState("sample-bottom", .samplePage(scrolledToBottom: true),
                     "«MyNotion — образец» прокручена вниз: чекбоксы, блоки-подстраницы с иконкой и без", section: "Страница"),
        GalleryState("empty-page", .emptyPage,
                     "Пустая страница: один пустой абзац с курсором и подсказкой", section: "Страница", narrowToo: true),
        GalleryState("untitled-page", .untitledPage,
                     "Пустое название: курсор в названии, подсказка «Без названия»", section: "Страница"),
        GalleryState("nested-lists", .nestedLists,
                     "Маркированные, нумерованные списки и чекбоксы трёх уровней, отмеченные чекбоксы", section: "Страница"),
        GalleryState("long-breadcrumb", .longBreadcrumb,
                     "Верхняя полоса с длинным путём страницы четвёртого уровня", section: "Страница", narrowToo: true),
        GalleryState("save-error-banner", .saveErrorBanner,
                     "Полоса «Изменения не сохранены…» над страницей", section: "Страница", narrowToo: true),
        GalleryState("page-top-bar", .pageTopBar,
                     "Верхняя полоса страницы: путь слева, «•••» справа", section: "Страницы и навигация"),
        GalleryState("favorite-star-empty", .favoriteStar(isFavorite: false),
                     "«☆» в верхней полосе: страница не в избранном, подсказка «Добавить в избранное»", section: "Страницы и навигация"),
        GalleryState("favorite-star-filled", .favoriteStar(isFavorite: true),
                     "«★» закрашена жёлтым: страница в избранном", section: "Страницы и навигация"),
        GalleryState("page-menu", .pageMenu,
                     "Меню «•••»: «Найти действие…», «Удалить в корзину», подвал «Изменено…, N слов»", section: "Страницы и навигация"),
    ]

    private static let blockStates: [GalleryState] = textBlockKinds.flatMap { kind in
        GalleryCaret.allCases.map { caret in
            let place = switch caret {
            case .none: "без курсора"
            case .inMiddle: "курсор в пустом блоке в середине"
            case .atEnd: "курсор в пустом блоке в конце страницы"
            }
            return GalleryState("block-\(kind.rawValue)-caret-\(caret.rawValue)", .block(kind, caret),
                                "Тип «\(name(of: kind))»: с текстом, пустой в середине и в конце; \(place)", section: "Типы блоков")
        }
    }

    private static let editingStates: [GalleryState] = [BlockKind.paragraph, .heading1, .bulletItem, .checkbox].map { kind in
        GalleryState("hover-block-\(kind.rawValue)", .blockHover(kind),
                     "Наведение на блок «\(name(of: kind))»: ручки «+ ⋮⋮» слева", section: "Правка",
                     narrowToo: kind == .paragraph)
    } + [
        GalleryState("slash-menu", .slashMenu(filter: ""), "Меню «/» в пустом абзаце, все типы", section: "Правка", narrowToo: true),
        GalleryState("slash-menu-filtered", .slashMenu(filter: "заг"), "Меню «/» с фильтром «заг»", section: "Правка"),
        GalleryState("block-menu", .blockMenu(turnInto: false),
                     "Меню блока по щелчку на «⋮⋮», как у Notion: тип блока, «Преобразовать в ▸», «Цвет ▸», черта, «Дублировать ⌘D», «Удалить Del»",
                     section: "Правка", narrowToo: true),
        GalleryState("block-menu-turn-into", .blockMenu(turnInto: true),
                     "Подменю «Преобразовать в» справа от меню блока: текущий тип с галочкой, список по высоте окна с прокруткой",
                     section: "Правка", narrowToo: true),
        GalleryState("bullet-shortcut-at-end", .bulletByShortcutAtEnd,
                     "Последний пустой блок стал пунктом от «- »: маркер с отступом, «Список» там, где начнётся текст", section: "Правка"),
        GalleryState("block-dragging", .blockDragging,
                     "Идёт перетаскивание за «⋮⋮»: копия пункта с вложенными едет за мышью, синяя линия — место сброса", section: "Правка"),
        GalleryState("formatted-selection", .formattedSelection,
                     "Выделенный текст с жирным, курсивом и зачёркнутым", section: "Правка"),
        GalleryState("selection-across-blocks", .selectionAcrossBlocks,
                     "Выделение текста через блоки: полосы по тексту построчно, между блоками просвет, номера не закрашены", section: "Правка"),
        GalleryState("block-selection", .blockSelection,
                     "Режим выделения блоков: светлый прямоугольник на каждый блок целиком, между блоками просвет, курсора нет",
                     section: "Правка"),
        GalleryState("format-bar", .formatBar(kindMenu: false),
                     "Панель форматирования под выделенным словом, у его конца, как у Notion: тип блока «Текст», кнопки, «Жирный» нажат (синий)", section: "Правка"),
        GalleryState("format-bar-type-menu", .formatBar(kindMenu: true),
                     "Панель форматирования с открытым списком типов: те же типы, что в меню «/», текущий отмечен галочкой", section: "Правка"),
        GalleryState("colors-on-page", .colorsOnPage,
                     "Цвета как у Notion: девять цветов текста и фона в строке, цветные блоки, подложка цитаты и выноски", section: "Правка"),
        GalleryState("color-menu-format-bar", .colorMenu(fromBlockMenu: false),
                     "Окно цветов под панелью форматирования: «Недавние», «Цвет текста» и «Цвет фона», у каждого цвета образец «A»",
                     section: "Правка"),
        GalleryState("color-menu-block", .colorMenu(fromBlockMenu: true),
                     "Окно цветов — подменю пункта «Цвет» меню блока, справа от меню, верх вровень со строкой", section: "Правка"),
        GalleryState("page-icon-add-hover", .pageIcon(.addIconHover),
                     "Мышь над шапкой страницы без иконки: серая «Добавить иконку» со значком над названием, как у Notion", section: "Правка"),
        GalleryState("page-icon-picker", .pageIcon(.picker),
                     "Окно выбора иконки под иконкой страницы: «Эмодзи», поиск, «Случайная», «Убрать», разделы и значки разделов внизу",
                     section: "Правка"),
        GalleryState("page-icon-picker-search", .pageIcon(.pickerSearch),
                     "Поиск «кот» в окне выбора иконки: найденные эмодзи без разделов, первый подсвечен", section: "Правка"),
        GalleryState("soft-line-breaks", .softLineBreaks,
                     "Блоки с переносами строк (Shift+Enter): маркер, номер и квадрат у первой строки, следующие — с отступом текста; курсор во второй строке",
                     section: "Правка"),
        GalleryState("selection-across-soft-breaks", .selectionAcrossSoftBreaks,
                     "Выделение через блоки с переносами строк: подложка на все строки каждого блока, соседние слиты", section: "Правка"),
    ]

    private static let sidebarStates: [GalleryState] = [
        GalleryState("sidebar-tree-expanded", .sidebarTree(collapsed: false),
                     "Дерево четырёх уровней, ветка «Проекты» развёрнута, длинное название в дереве", section: "Боковая панель",
                     narrowToo: true),
        GalleryState("sidebar-tree-collapsed", .sidebarTree(collapsed: true),
                     "Ветка «Проекты» свёрнута", section: "Боковая панель"),
        GalleryState("sidebar-row-hover", .sidebarRowHover(longTitle: false),
                     "Наведение на строку дерева: «⋯ +» справа, стрелка вместо иконки", section: "Боковая панель"),
        GalleryState("sidebar-row-hover-long-title", .sidebarRowHover(longTitle: true),
                     "Наведение на строку с длинным названием: название обрезано перед «⋯ +»", section: "Боковая панель",
                     narrowToo: true),
        GalleryState("sidebar-selected-row", .sidebarSelectedRow,
                     "Открыта страница четвёртого уровня: её строка выбрана", section: "Боковая панель"),
        GalleryState("sidebar-renaming", .sidebarRenaming,
                     "Переименование строки дерева: название выделено в поле", section: "Боковая панель"),
        GalleryState("sidebar-search-results", .search(nothingFound: false),
                     "Поиск «стран»: под полем выдача с заголовком «Найдено: N» — сначала названия, потом текст; путь родителей серым, найденное синим, первая строка выбрана; корзина не ищется",
                     section: "Боковая панель", narrowToo: true),
        GalleryState("sidebar-search-nothing-found", .search(nothingFound: true),
                     "Поиск слова, которого нет: «Ничего не найдено» и пояснение про корзину по центру карточки под полем", section: "Боковая панель"),
        GalleryState("sidebar-recent-and-favorites", .sidebarSections(.recentAndFavorites),
                     "Над «Страницами»: «Недавние» (пять строк и «Показать все») и «Избранное»; открытая страница подсвечена",
                     section: "Боковая панель", narrowToo: true),
        GalleryState("sidebar-favorites-collapsed", .sidebarSections(.favoritesCollapsed),
                     "«Избранное» свёрнуто: остался заголовок, «Недавние» и «Страницы» на месте", section: "Боковая панель"),
        GalleryState("sidebar-favorite-row-menu", .sidebarSections(.favoriteRowMenu),
                     "Меню строки в «Избранном»: «Убрать из избранного» среди остальных пунктов", section: "Боковая панель"),
        GalleryState("sidebar-hidden", .sidebarHidden,
                     "Боковая панель свёрнута шторкой: шторка у светофора, страница во всю ширину", section: "Боковая панель",
                     narrowToo: true),
    ]

    private static let syncStates: [GalleryState] = [
        GalleryState("sync-badge-ready", .sync(.badgeReady), "Значок синхронизации внизу панели: «Синхронизировано»",
                     section: "Синхронизация", narrowToo: true),
        GalleryState("sync-badge-sending", .sync(.badgeSending), "Значок синхронизации: «Отправка…»", section: "Синхронизация"),
        GalleryState("sync-badge-error", .sync(.badgeError), "Значок синхронизации: «Ошибка синхронизации» красным",
                     section: "Синхронизация"),
        GalleryState("sync-badge-error-details", .sync(.badgeErrorDetails),
                     "Щелчок по значку: что случилось (нет связи — правки уйдут позже), когда всё сошлось, «Настройки…»",
                     section: "Синхронизация"),
        GalleryState("sync-conflict-label", .sync(.conflictLabel),
                     "Блок, который правили на двух Mac: оранжевая метка «Две версии» справа", section: "Синхронизация",
                     narrowToo: true),
        GalleryState("sync-conflict-comparison", .sync(.conflictComparison),
                     "Окно сравнения: «Сейчас в блоке» и «Вторая версия · с MacBook Air», «Оставить эту», «Оставить обе»",
                     section: "Синхронизация"),
        GalleryState("sync-settings-disconnected", .sync(.settingsDisconnected),
                     "Настройки синхронизации, не подключено: сервер, имя Mac, код со второго Mac или токен первого",
                     section: "Синхронизация"),
        GalleryState("sync-settings-join-code", .sync(.settingsJoinCode),
                     "«Добавить Mac»: код подключения, предупреждение «не пересылайте в мессенджерах», устройства",
                     section: "Синхронизация"),
        GalleryState("sync-notice-returned-from-trash", .sync(.noticeReturnedFromTrash),
                     "Уведомление внизу окна: страница возвращена из корзины, её правили на другом Mac", section: "Синхронизация"),
    ]

    private static let trashStates: [GalleryState] = [
        GalleryState("trash-row", .trash(.rowAtBottom), "Строка «Корзина» внизу панели в низком окне", section: "Корзина",
                     narrowToo: true),
        GalleryState("trash-open", .trash(.open), "Окно корзины с записями", section: "Корзина", narrowToo: true),
        GalleryState("trash-confirm-delete-forever", .trash(.confirmDeleteForever),
                     "Диалог подтверждения «Удалить навсегда»", section: "Корзина"),
        GalleryState("trash-open-empty", .trash(.openEmpty), "Окно пустой корзины", section: "Корзина"),
    ]

    private static let importStates: [GalleryState] = [
        GalleryState("notion-import-progress", .notionImport(.progress),
                     "Перенос из Notion идёт: карточка хода внизу окна с кнопкой «Остановить»", section: "Импорт из Notion", narrowToo: true),
        GalleryState("notion-import-repeat", .notionImport(.repeatWarning),
                     "Этот файл из Notion уже переносили: вопрос до начала", section: "Импорт из Notion"),
        GalleryState("notion-import-report", .notionImport(.report),
                     "Итог переноса: сколько страниц, где лежат, что стало простым текстом", section: "Импорт из Notion", narrowToo: true),
    ]

    private static let exportStates: [GalleryState] = [
        GalleryState("markdown-export-progress", .markdownExport(.progress),
                     "Выгрузка в Markdown идёт: карточка хода внизу окна", section: "Выгрузка в Markdown", narrowToo: true),
        GalleryState("markdown-export-done", .markdownExport(.done),
                     "Выгрузка готова: «Показать в Finder» и «Закрыть»", section: "Выгрузка в Markdown"),
        GalleryState("markdown-export-failed", .markdownExport(.failed),
                     "Выгрузка не удалась: понятная ошибка и «Закрыть»", section: "Выгрузка в Markdown"),
    ]
}
