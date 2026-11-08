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
    /// Обложка и вид страницы (US1).
    case pageCover(GalleryPageCover)
    /// Меню «•••» с открытым подменю «Вид страницы ›» (US1).
    case pageMenuAppearance
    /// Синхронизация между Mac (US5): значок, «Две версии», настройки подключения, уведомление.
    case sync(GallerySync)
    /// Импорт из Notion (US6): карточка хода, вопрос о повторе той же выгрузки, отчёт.
    case notionImport(GalleryNotionImport)
    /// Выгрузка в Markdown (FR-017): карточка хода, итог с «Показать в Finder», ошибка.
    case markdownExport(GalleryMarkdownExport)
    /// Вкладки окна (US3): полоса с 1, 3 и 12 вкладками, «×» под мышью, панель спрятана, «Открыть в новой вкладке»,
    /// «Недавние» во вкладке, заглушка «Страница в корзине».
    case tabs(GalleryTabs)
    /// Окно «Переместить в…» (US4): без запроса — недавние и дерево, своя страница серая; с запросом — выдача поиска.
    case movePicker(GalleryMovePicker)
    /// История версий (US6).
    case versionHistory(GalleryVersionHistory)
    /// Шаблоны (US7): раздел «Шаблоны» в панели, строки на пустой странице, поиск «Ещё шаблоны…».
    case templates(GalleryTemplates)
    /// Обратные ссылки (US5): строка «↗ 3 обратные ссылки» под названием и открытый список источников.
    case backlinks(GalleryBacklinks)
    /// Базы (004): пустая новая база и таблица эталона; истории 004 добавляют свои состояния.
    case databases(GalleryDatabases)
    /// Панель ИИ-агента (008).
    case aiChat(GalleryAIChat)
}

/// Панель ИИ-агента справа (008; сверка — `ai-ref-27..30.png`).
public enum GalleryAIChat: CaseIterable, Sendable {
    /// Пустой чат: «Чем помочь?» и просьбы про открытую страницу.
    case empty
    /// Ответ после рассуждений и вызовов инструментов: шаги свёрнуты в одну строку-сводку.
    case toolReply
    /// Тот же ответ, сводка шагов раскрыта.
    case stepsExpanded
    /// Открытый список моделей над полем ввода.
    case modelMenu
    /// Открытый список уровней рассуждений.
    case levelMenu
    /// Прошлые чаты под заголовком, по срокам.
    case pastChats
    /// Меню строки прошлого чата с «Удалить».
    case deleteMenu
}

/// Базы данных (004, contracts/database-ui.md).
public enum GalleryDatabases: Hashable, Sendable, CaseIterable {
    /// Новая база: вид «Таблица», одна колонка «Название», строк нет.
    case empty
    /// Таблица эталона баз: «Задачи», все типы свойств, плашки вариантов.
    case sampleTable
    // US1: таблица в работе.
    case inlineEmpty, inlineOverview, rowHover, cellSelection, cellEditing, columnMenu, typePicker, editProperty, propertiesWindow,
         deleteConfirm, rowMenu, rowPage, sidePeek, centerPeek
    /// Состояния, которых не было: строки выбраны флажками (полоса «N выбрано») и поиск без результата.
    case rowsSelected, searchNoResults
    /// US5: редактор формулы — пустой, с итогом, с ошибкой, с кругом; ячейки формул всех типов итога.
    case formulaEditorEmpty
    case formulaEditorResult
    case formulaEditorError
    case formulaEditorCycle
    case formulaCells
    /// US4: панель новой связи и настроенной двусторонней, окна «Связана с» и «Лимит», панель сводки и «Вычислить»,
    /// таблица «Проекты» со сводками и ответной связью.
    case relationNewSettings
    case relationSettings
    case relationTargetChooser
    case relationLimitChooser
    case rollupSettings
    case rollupNumberSettings
    case rollupCalculateMenu
    case relationProjectsTable
    case relationPicker
    /// US6: «Создать ▾» без шаблонов и с шаблонами, меню «•••» шаблона, правка шаблона по центру, «Быстрый выбор» даты шаблона.
    case rowTemplatesMenuEmpty, rowTemplatesMenu, rowTemplateItemMenu, rowTemplateEditor, rowTemplateDateShortcuts
    /// US3: вид — строка вида с синими значками и плашками, окна фильтра, сортировки, видимости, группировки, раскладки,
    /// настройки вида, меню вкладки, поиск, таблица с группами и итогами, перенос текста, меню «Посчитать».
    case viewBarActive, viewFilterSimple, viewFilterAdvanced, viewFilterDate, viewSorts, viewVisibility, viewGrouping, viewGroupedTable,
         viewWrapText, viewLayout, viewSettings, viewTabMenu, viewSearch, viewCalculateMenu
    /// US2: окна выбора, статуса, даты, файлов, меню варианта, настройки выбора, статуса и числа, плашки и полоса с кольцом.
    case typeSelectPicker, typeMultiSelectPicker, typeStatusPicker, typeOptionMenu, typeDatePicker, typeDateFormats, typeFilesPopup,
         typeSelectSettings, typeStatusSettings, typeNumberSettings, typeChipsAndMeters
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
    /// Всё отправлено: внизу панели синхронизации не видно.
    case badgeReady
    /// Идёт отправка: внизу панели синхронизации не видно.
    case badgeSending
    /// Строка внизу панели: ошибка (нет связи).
    case badgeError
    /// Подробности ошибки по щелчку на значке.
    case badgeErrorDetails
    /// Блок в конфликте: оранжевая метка «Две версии».
    case conflictLabel
    /// Окно сравнения двух версий с выбором.
    case conflictComparison
    /// Настройки: синхронизация не включена — подключить кодом или токеном.
    case settingsDisconnected
    /// Настройки: «Добавить Mac или iPhone» показал код с предупреждением, список устройств.
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

public enum GalleryPageCover: String, Hashable, Sendable, CaseIterable {
    /// Мышь над шапкой страницы без обложки: «Добавить иконку» и «Добавить обложку».
    case addHover
    /// Обложка из галереи и иконка, заходящая на неё.
    case gallery
    /// Своя картинка обложкой, без иконки.
    case image
    /// Мышь над обложкой: «Сменить обложку», «Переместить».
    case hover
    /// Режим «Переместить»: подсказка и «Сохранить положение», «Отмена».
    case reposition
    /// Окно «Сменить обложку», вкладки «Галерея» и «Загрузить».
    case pickerGallery
    case pickerUpload
    /// Образец страницы мелким шрифтом и во всю ширину.
    case smallText
    case fullWidth
}

public enum GalleryTrash: String, Hashable, Sendable, CaseIterable {
    /// Панель без строки «Корзина»: корзина открывается из меню.
    case sidebarWithoutRow
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

/// Шаблоны страниц (US7; в Notion 7.39 «Шаблоны» — отдельный раздел панели и строки на пустой странице).
public enum GalleryTemplates: CaseIterable, Sendable {
    /// Раздел «Шаблоны» под деревом «Страниц»: три шаблона, у одного — подстраницы.
    case sidebarSection
    /// Пустая новая страница: серый «Шаблоны» и строки шаблонов под первой строкой.
    case emptyPageRows
    /// Строк больше пяти: «Ещё шаблоны…» открыло поиск по шаблонам.
    case searchPopover
}

/// История версий (US6; сверка — `notion-version-*.png`).
public enum GalleryVersionHistory: CaseIterable, Sendable {
    /// Список «1 минута», выбрана прошлая версия: справа она с подсветкой отличий.
    case list
    /// Группировка «15 минут».
    case grouped
    /// Открытый список «Группировать изменения»: 1 минута, 15 минут, 1 час, у выбранной — галочка.
    case groupingMenu
    /// Раскрытая версия: «← Все версии» и что менялось.
    case details
    /// Окно «Что будет восстановлено».
    case restoreDialog
    /// Полоса «Страница восстановлена» над страницей.
    case restoredBanner
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
        + trashStates + importStates + exportStates + syncStates + tabsStates + copiesStates + versionHistoryStates + templatesStates + backlinksStates
        + databaseStates + aiChatStates

    static let aiChatStates: [GalleryState] = [
        GalleryState("ai-chat-empty", .aiChat(.empty), "Панель ИИ-агента: пустой чат и просьбы про страницу", section: "ИИ-агент"),
        GalleryState("ai-chat-tool-reply", .aiChat(.toolReply), "Ответ: шаги агента свёрнуты в строку «Работал … с»", section: "ИИ-агент"),
        GalleryState("ai-chat-steps-expanded", .aiChat(.stepsExpanded), "Сводка шагов раскрыта: рассуждения и вызовы инструментов списком", section: "ИИ-агент"),
        GalleryState("ai-chat-model-menu", .aiChat(.modelMenu), "Список моделей над полем ввода", section: "ИИ-агент"),
        GalleryState("ai-chat-level-menu", .aiChat(.levelMenu), "Список уровней рассуждений", section: "ИИ-агент"),
        GalleryState("ai-chat-past-chats", .aiChat(.pastChats), "Прошлые чаты по срокам с поиском", section: "ИИ-агент"),
        GalleryState("ai-chat-delete-menu", .aiChat(.deleteMenu), "Меню строки прошлого чата: удалить на всех устройствах", section: "ИИ-агент"),
    ]

    /// Базы (004): этап 0 — пустая база и таблица эталона; истории добавляют свои строки в конец списка.
    static let databaseStates: [GalleryState] = [
        GalleryState("database-empty", .databases(.empty), "Новая база: вид «Таблица», колонка «Название», строк нет", section: "Базы"),
        GalleryState("database-sample-table", .databases(.sampleTable), "Таблица эталона «Задачи»: все типы, плашки, флажки, даты", section: "Базы"),
        GalleryState("database-inline-empty", .databases(.inlineEmpty), "Встроенная база в странице: серое «Новая база», колонка «Название»", section: "Базы"),
        GalleryState("database-inline-overview", .databases(.inlineOverview), "«Обзор»: встроенная база по пределу 50 и «Загрузить ещё»", section: "Базы"),
        GalleryState("database-row-hover", .databases(.rowHover), "Наведение строки: «+», «⠿», флажок слева, «ОТКРЫТЬ» у названия", section: "Базы"),
        GalleryState("database-cell-selection", .databases(.cellSelection), "Выделение ячеек прямоугольником (⇧-стрелки, протяжка)", section: "Базы"),
        GalleryState("database-cell-editing", .databases(.cellEditing), "Правка ячейки названия на месте", section: "Базы"),
        GalleryState("database-column-menu", .databases(.columnMenu), "Меню колонки: имя, «Изменить свойство», «Сменить тип», вставить, дублировать, удалить", section: "Базы"),
        GalleryState("database-type-picker", .databases(.typePicker), "«+» в шапке: «Название свойства…» и типы в две колонки", section: "Базы"),
        GalleryState("database-edit-property", .databases(.editProperty), "Панель «Изменить свойство» справа", section: "Базы"),
        GalleryState("database-properties-window", .databases(.propertiesWindow), "Окно «Свойства» базы с «Удалёнными свойствами»", section: "Базы"),
        GalleryState("database-delete-confirm", .databases(.deleteConfirm), "Подтверждение удаления свойства", section: "Базы"),
        GalleryState("database-row-menu", .databases(.rowMenu), "Меню строки (правый щелчок)", section: "Базы"),
        GalleryState("database-rows-selected", .databases(.rowsSelected), "Три строки отмечены флажками: полоса «Выбрано: 3»", section: "Базы"),
        GalleryState("database-search-no-results", .databases(.searchNoResults), "Поиск без результата: пустая таблица под строкой вида",
                     section: "Базы"),
        GalleryState("database-row-page", .databases(.rowPage), "Строка на всю страницу: свойства под названием, «+ Добавить свойство»", section: "Базы"),
        GalleryState("database-side-peek", .databases(.sidePeek), "Строка сбоку: таблица слева рабочая", section: "Базы"),
        GalleryState("database-center-peek", .databases(.centerPeek), "Строка по центру поверх затемнения", section: "Базы"),
        // US5, сверка — `notion-formula-editor*.png`.
        GalleryState("formula-editor-empty", .databases(.formulaEditorEmpty), "Редактор формулы пустой: «Ваша формула», «Нет итога», список свойств и функций",
                     section: "Базы"),
        GalleryState("formula-editor-result", .databases(.formulaEditorResult), "Редактор с формулой: плашка свойства, итог первой строки, «Тип: текст»",
                     section: "Базы"),
        GalleryState("formula-editor-error", .databases(.formulaEditorError), "Редактор с ошибкой типов: текст по-русски, место подчёркнуто, «Готово» неактивно",
                     section: "Базы"),
        GalleryState("formula-editor-cycle", .databases(.formulaEditorCycle), "Редактор с кругом «Итог → Сумма → Итог», «Готово» неактивно", section: "Базы"),
        GalleryState("formula-cells", .databases(.formulaCells), "Ячейки формул всех типов итога: число, текст, флажок, дата, список, страницы",
                     section: "Базы"),
        // US4, сверка — `notion-relation-*.png`, `notion-rollup-*.png`.
        GalleryState("relation-new-settings", .databases(.relationNewSettings), "Новая связь: «Связана с — Выбрать», «Лимит», «Ответное свойство» выключено",
                     section: "Базы"),
        GalleryState("relation-settings", .databases(.relationSettings), "Связь «Проект»: «Связана с — Проекты» серым, лимит, ответное свойство «Задачи»",
                     section: "Базы"),
        GalleryState("relation-target-chooser", .databases(.relationTargetChooser), "Окно «Связать с базой»: «Эта база» и базы по названию", section: "Базы"),
        GalleryState("relation-limit-chooser", .databases(.relationLimitChooser), "Окно лимита: «1 страница» и «Без лимита» с галочкой", section: "Базы"),
        GalleryState("rollup-settings", .databases(.rollupSettings), "Сводка «Сумма часов»: «Связь — Задачи», «Свойство — Часы», «Вычислить — Сумма»",
                     section: "Базы"),
        GalleryState("rollup-number-settings", .databases(.rollupNumberSettings), "Числовая сводка: формат, знаки после запятой, полоса, цвет и делитель",
                     section: "Базы"),
        GalleryState("rollup-calculate-menu", .databases(.rollupCalculateMenu), "Меню «Вычислить»: как есть, уникальные, количество, проценты, числа",
                     section: "Базы"),
        GalleryState("relation-picker", .databases(.relationPicker), "Окно ячейки связи: поиск, «1 выбрано» с «−», «Выбрать ещё», «В «Проекты»»",
                     section: "Базы"),
        GalleryState("relation-projects-table", .databases(.relationProjectsTable), "«Проекты»: ответная связь «Задачи» плашками, сводки числом", section: "Базы"),
        // US6, сверка — `notion-new-dropdown-templates*.png`, `notion-template-*.png`.
        GalleryState("row-templates-menu-empty", .databases(.rowTemplatesMenuEmpty), "«Создать ▾» новой базы: подсказка и «+ Новый шаблон»", section: "Базы"),
        GalleryState("row-templates-menu", .databases(.rowTemplatesMenu), "«Создать ▾»: «Баг» по умолчанию, «Созвон», «Пустая страница», «+ Новый шаблон»",
                     section: "Базы"),
        GalleryState("row-template-item-menu", .databases(.rowTemplateItemMenu), "«•••» шаблона: Изменить, Дублировать, Удалить", section: "Базы"),
        GalleryState("row-template-editor", .databases(.rowTemplateEditor), "Шаблон «Баг» по центру: янтарная полоса, «Срок» — «Сегодня», чек-лист",
                     section: "Базы"),
        GalleryState("row-template-date-shortcuts", .databases(.rowTemplateDateShortcuts), "Окно даты шаблона: «Быстрый выбор» — «Сейчас», «Сегодня»",
                     section: "Базы"),
        // US3, сверка — `notion-filter-*.png`, `notion-sort-*.png`, `notion-group-*.png`, `notion-view-*.png`, `notion-calculate-*.png`.
        GalleryState("view-bar-active", .databases(.viewBarActive), "Вид «Задачи — работа»: синие фильтр и сортировка, плашки, группы по статусу",
                     section: "Базы"),
        GalleryState("view-filter-simple", .databases(.viewFilterSimple), "Окно плашки фильтра: «Статус не равно», флажки вариантов", section: "Базы"),
        GalleryState("view-filter-advanced", .databases(.viewFilterAdvanced), "Расширенный фильтр: «Где», «И/Или», вложенная группа в рамке",
                     section: "Базы"),
        GalleryState("view-filter-date", .databases(.viewFilterDate), "Фильтр по дате: «Относительно сегодня», «Эта неделя»", section: "Базы"),
        GalleryState("view-sorts", .databases(.viewSorts), "Окно сортировки: два уровня с ручками, «+ Добавить сортировку»", section: "Базы"),
        GalleryState("view-visibility", .databases(.viewVisibility), "Видимость свойств: показанные и скрытые, глаз и ручка", section: "Базы"),
        GalleryState("view-grouping", .databases(.viewGrouping), "Группировка: «Группировать по», порядок, «Скрывать пустые», список групп",
                     section: "Базы"),
        GalleryState("view-grouped-table", .databases(.viewGroupedTable), "Таблица с группами: заголовки, свёрнутая группа, итоги под группами",
                     section: "Базы"),
        GalleryState("view-wrap-text", .databases(.viewWrapText), "Перенос текста в колонке «Описание»: высота строки по тексту", section: "Базы"),
        GalleryState("view-layout", .databases(.viewLayout), "Раскладка: «Таблица», перенос всего текста, «Открывать строки», «Предел загрузки»",
                     section: "Базы"),
        GalleryState("view-settings", .databases(.viewSettings), "Настройки вида справа: имя, раскладка, видимость, фильтр, сортировка, группировка",
                     section: "Базы"),
        GalleryState("view-tab-menu", .databases(.viewTabMenu), "Меню вкладки вида: переименовать, изменить, дублировать, удалить", section: "Базы"),
        GalleryState("view-search", .databases(.viewSearch), "Поиск в базе «отчёт»: поле в строке вида, найденное подсвечено", section: "Базы"),
        GalleryState("view-calculate-menu", .databases(.viewCalculateMenu), "Строка итогов и меню «Посчитать ›»", section: "Базы"),
        // US2, сверка — `notion-select-*.png`, `notion-status-cell-popup.png`, `notion-edit-property-*.png`, `notion-date-format-options.png`.
        GalleryState("type-select-picker", .databases(.typeSelectPicker), "Окно выбора: «Найти вариант…», «Выберите вариант или создайте его», ручки",
                     section: "Базы"),
        GalleryState("type-multi-select-picker", .databases(.typeMultiSelectPicker), "Множественный выбор: выбранные плашки с «×», поиск и «Создать»",
                     section: "Базы"),
        GalleryState("type-status-picker", .databases(.typeStatusPicker), "Окно статуса: группы «К выполнению», «В работе», «Завершено»", section: "Базы"),
        GalleryState("type-option-menu", .databases(.typeOptionMenu), "Меню «⋯» варианта: имя, «Удалить», 10 цветов с галочкой", section: "Базы"),
        GalleryState("type-date-picker", .databases(.typeDatePicker), "Окно даты: начало и конец, календарь с понедельника, время, «Напомнить»",
                     section: "Базы"),
        GalleryState("type-date-formats", .databases(.typeDateFormats), "Окно даты с подменю «Формат даты»", section: "Базы"),
        GalleryState("type-files-popup", .databases(.typeFilesPopup), "Окно файлов: файлы и ссылка в ячейке, «Загрузить» / «Ссылка»", section: "Базы"),
        GalleryState("type-select-settings", .databases(.typeSelectSettings), "Изменить свойство выбора: «Сортировка», варианты с ручками", section: "Базы"),
        GalleryState("type-status-settings", .databases(.typeStatusSettings), "Изменить свойство статуса: три группы с «+»", section: "Базы"),
        GalleryState("type-number-settings", .databases(.typeNumberSettings), "Изменить свойство числа: формат, знаки, «Показывать как» — полоса",
                     section: "Базы"),
        GalleryState("type-chips-meters", .databases(.typeChipsAndMeters), "Плашки 10 цветов, статус с точкой, полоса и кольцо числа, даты с концом",
                     section: "Базы"),
    ]

    /// Обратные ссылки (US5, contracts/pages-ui.md, «Обратные ссылки»): строка под названием и список источников.
    static let backlinksStates: [GalleryState] = [
        GalleryState("backlinks-row", .backlinks(.row), "Под названием серая строка «↗ 3 обратные ссылки»", section: "Ссылки"),
        GalleryState("backlinks-list", .backlinks(.list), "Щелчок по строке: список страниц — иконка, название, путь серым", section: "Ссылки"),
    ]

    /// Копии (US4, contracts/pages-ui.md, «Окно «Переместить в»»; сверка — снимок Notion 7.39 `notion-move-to.png`).
    /// Пункт «Переместить в» меню блока — в снимке `block-menu`.
    static let copiesStates: [GalleryState] = [
        GalleryState("move-picker", .movePicker(.recentAndTree), "«Переместить в…» страницы: недавние, дерево, сама страница серая",
                     section: "Копии"),
        GalleryState("move-picker-query", .movePicker(.query), "«Переместить в…» с запросом: выдача поиска с путём", section: "Копии"),
    ]

    /// История версий (US6, contracts/pages-ui.md, «История версий»).
    static let versionHistoryStates: [GalleryState] = [
        GalleryState("version-history-list", .versionHistory(.list), "«История версий»: список, прошлая версия с подсветкой отличий",
                     section: "История версий", narrowToo: true),
        GalleryState("version-history-grouped", .versionHistory(.grouped), "Группировка «15 минут»", section: "История версий"),
        GalleryState("version-history-grouping-menu", .versionHistory(.groupingMenu), "Открытый список «Группировать изменения»",
                     section: "История версий"),
        GalleryState("version-history-details", .versionHistory(.details), "Раскрытая версия: что менялось", section: "История версий"),
        GalleryState("version-history-restore", .versionHistory(.restoreDialog), "Окно «Что будет восстановлено»",
                     section: "История версий"),
        GalleryState("version-restored-banner", .versionHistory(.restoredBanner), "После восстановления: полоса «Страница восстановлена»",
                     section: "История версий"),
    ]

    /// Шаблоны (US7, contracts/pages-ui.md, «Шаблоны на пустой странице»). Снимаются последними: образец шаблонов
    /// после съёмки снимается, чтобы строки шаблонов не попали на другие пустые страницы.
    static let templatesStates: [GalleryState] = [
        GalleryState("templates-sidebar", .templates(.sidebarSection), "Раздел «Шаблоны» в панели: три шаблона", section: "Шаблоны"),
        GalleryState("templates-empty-page", .templates(.emptyPageRows), "Пустая страница: заголовок «Шаблоны» и строки шаблонов",
                     section: "Шаблоны", narrowToo: true),
        GalleryState("templates-search", .templates(.searchPopover), "Больше пяти шаблонов: «Ещё шаблоны…» открыло поиск", section: "Шаблоны"),
    ]

    /// Вкладки окна (US3, contracts/pages-ui.md, «Верхняя полоса окна»; сверка — снимок Notion 7.39 `notion-sidebar-tabs-topbar.png`).
    static let tabsStates: [GalleryState] = [
        GalleryState("tabs-one", .tabs(.one), "Одна вкладка: «‹ ›» серые, вкладка цветом страницы, «+»", section: "Вкладки"),
        GalleryState("tabs-three", .tabs(.three), "Три вкладки, активная — средняя; «‹» можно, «›» нельзя", section: "Вкладки",
                     narrowToo: true),
        GalleryState("tabs-twelve", .tabs(.twelve), "Двенадцать вкладок сжаты поровну, названия обрезаны", section: "Вкладки",
                     narrowToo: true),
        GalleryState("tabs-hover", .tabs(.hover), "Мышь над неактивной вкладкой: «×»", section: "Вкладки"),
        GalleryState("tabs-sidebar-hidden", .tabs(.sidebarHidden), "Панель спрятана: полоса сразу за шторкой", section: "Вкладки"),
        GalleryState("tabs-new-tab-search", .tabs(.newTabSearch), "⌘T: «Открыть в новой вкладке…» — недавние по дням",
                     section: "Вкладки"),
        GalleryState("tabs-recent-pages", .tabs(.recentPages), "«Показать все»: «Недавние» во вкладке", section: "Вкладки"),
        GalleryState("tabs-trashed-page", .tabs(.trashedPage), "Страница вкладки в корзине: «Страница в корзине», «Вернуть»",
                     section: "Вкладки"),
    ]

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
        case .database: "встроенная база"
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
        GalleryState("page-menu-appearance", .pageMenuAppearance,
                     "Меню «•••» → «Вид страницы ›»: «Мелкий шрифт», «Широкая страница»", section: "Страницы и навигация"),
    ] + pageCoverStates

    private static let pageCoverStates: [GalleryState] = [
        GalleryState("page-cover-add-hover", .pageCover(.addHover), "Шапка без обложки под мышью: «Добавить иконку», «Добавить обложку»",
                     section: "Страницы и навигация"),
        GalleryState("page-cover-gallery", .pageCover(.gallery), "Обложка из галереи, иконка заходит на неё", section: "Страницы и навигация",
                     narrowToo: true),
        GalleryState("page-cover-image", .pageCover(.image), "Своя картинка обложкой, страница без иконки", section: "Страницы и навигация"),
        GalleryState("page-cover-hover", .pageCover(.hover), "Мышь над обложкой: «Сменить обложку», «Переместить»",
                     section: "Страницы и навигация"),
        GalleryState("page-cover-reposition", .pageCover(.reposition),
                     "«Переместить»: «Перетащите картинку…», «Сохранить положение», «Отмена»", section: "Страницы и навигация"),
        GalleryState("page-cover-picker-gallery", .pageCover(.pickerGallery), "Окно «Сменить обложку», «Галерея»: цвета и градиенты",
                     section: "Страницы и навигация"),
        GalleryState("page-cover-picker-upload", .pageCover(.pickerUpload), "Окно «Сменить обложку», «Загрузить»",
                     section: "Страницы и навигация"),
        GalleryState("page-small-text", .pageCover(.smallText), "Образец страницы мелким шрифтом", section: "Страницы и навигация"),
        GalleryState("page-full-width", .pageCover(.fullWidth), "Образец страницы во всю ширину", section: "Страницы и навигация"),
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
        GalleryState("sync-badge-ready", .sync(.badgeReady), "Всё синхронизировано: внизу панели нет ни строки, ни линии",
                     section: "Синхронизация", narrowToo: true),
        GalleryState("sync-badge-sending", .sync(.badgeSending), "Идёт отправка: внизу панели по-прежнему ничего нет",
                     section: "Синхронизация"),
        GalleryState("sync-badge-error", .sync(.badgeError), "Внизу панели появляется «Ошибка синхронизации» красным, над ней линия",
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
                     "«Добавить Mac или iPhone»: код подключения, предупреждение «не пересылайте в мессенджерах», устройства",
                     section: "Синхронизация"),
        GalleryState("sync-notice-returned-from-trash", .sync(.noticeReturnedFromTrash),
                     "Уведомление внизу окна: страница возвращена из корзины, её правили на другом Mac", section: "Синхронизация"),
    ]

    private static let trashStates: [GalleryState] = [
        GalleryState("trash-row", .trash(.sidebarWithoutRow), "Низ панели в низком окне: строки «Корзина» нет", section: "Корзина",
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

/// Состояния обратных ссылок для галереи (US5).
public enum GalleryBacklinks: Hashable, Sendable, CaseIterable {
    case row
    case list
}

/// Состояния окна «Переместить в…» для галереи (US4).
public enum GalleryMovePicker: Hashable, Sendable {
    case recentAndTree
    case query
}

/// Состояния вкладок окна для галереи (US3).
public enum GalleryTabs: Hashable, Sendable {
    case one
    case three
    case twelve
    case hover
    case sidebarHidden
    case newTabSearch
    case recentPages
    case trashedPage
}
