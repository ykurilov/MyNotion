import Foundation
import NotesCore
import UIGallery

/// Страницы временной базы галереи (`--ui-gallery`): образец, страница на каждый тип блока, списки,
/// дерево четырёх уровней с длинными названиями, свёрнутая ветка и корзина с записями.
struct GalleryLibrary {
    /// Страница одного типа блока: заполненный блок, пустой, абзац, пустой в конце.
    struct BlockKindPage {
        let pageId: UUID
        let emptyInMiddle: UUID
        let paragraphAfterEmpty: UUID
        let emptyAtEnd: UUID
    }

    let sample: PageContent
    let blockKindPages: [BlockKind: BlockKindPage]
    let nestedLists: UUID
    /// Блоки с переносами строк (Shift+Enter): абзац, пункты и чекбокс в несколько строк.
    let softBreaksPage: UUID
    let softBreaks: [UUID]
    /// «Первый уровень» маркированного списка: у него два вложенных пункта.
    let nestedListGroup: UUID
    let emptyPage: UUID
    let untitledPage: UUID
    /// «Проекты» → … → страница четвёртого уровня; у всех длинные названия.
    let projects: UUID
    let projectBranch: [UUID]
    let deepPage: UUID
    let longTitlePage: UUID
    let archive: UUID
    /// Страница, в которой набирают текст для полосы «Изменения не сохранены».
    let notesPage: UUID
    let notesBlock: UUID
    /// Страница, где один блок правили на двух Mac: «Две версии» (US5).
    let conflictPage: UUID
    let conflictBlock: UUID

    /// Первый блок образца нужного типа.
    func sampleBlock(_ kind: BlockKind) -> Block? {
        sample.blocks.first { $0.kind == kind }
    }

    static func create(in store: NotesStore) throws -> GalleryLibrary {
        let samplePage = try VisualSamplePage.ensure(in: store)
        guard let sample = try store.pageContent(samplePage.id) else { throw NotesStoreError.pageNotFound(samplePage.id) }
        return try store.write { transaction in
            var lastRootKey = try transaction.allPages().filter { $0.parentId == nil }.map(\.sortKey).max()
            let now = Date()
            func page(_ title: String, icon: String? = nil, parent: UUID? = nil, trashed: Bool = false) throws -> UUID {
                let sortKey: FractionalSortKey
                if parent == nil {
                    sortKey = .between(lastRootKey, nil)
                    lastRootKey = sortKey
                } else {
                    let siblings = try transaction.allPages().filter { $0.parentId == parent }.map(\.sortKey)
                    sortKey = .between(siblings.max(), nil)
                }
                let page = Page(title: title, icon: icon, parentId: parent, sortKey: sortKey,
                                trashedAt: trashed ? now : nil, createdAt: now, updatedAt: now)
                try transaction.insertPage(page)
                return page.id
            }
            func blocks(_ pageId: UUID, _ items: [(BlockKind, String, Int, Bool)]) throws -> [UUID] {
                var sortKey: FractionalSortKey?
                return try items.map { kind, text, indent, checked in
                    sortKey = .between(sortKey, nil)
                    return try transaction.insertBlock(Block(pageId: pageId, kind: kind, text: InlineText(text), indent: indent,
                                                             isChecked: checked, sortKey: sortKey!)).id
                }
            }

            let kindsParent = try page("Типы блоков", icon: "🧱")
            _ = try blocks(kindsParent, [(.paragraph, "Страницы с каждым типом блока.", 0, false)])
            var blockKindPages: [BlockKind: BlockKindPage] = [:]
            for kind in GalleryCatalog.textBlockKinds {
                let pageId = try page(Self.pageTitle(of: kind), parent: kindsParent)
                let ids = try blocks(pageId, [
                    (kind, "Блок с текстом: \(Self.pageTitle(of: kind).lowercased())", 0, false),
                    (kind, "", 0, false),
                    (.paragraph, "Абзац после пустого блока.", 0, false),
                    (kind, "", 0, false),
                ])
                blockKindPages[kind] = BlockKindPage(pageId: pageId, emptyInMiddle: ids[1], paragraphAfterEmpty: ids[2], emptyAtEnd: ids[3])
            }

            let softBreaksPage = try page("Переносы строк", parent: kindsParent)
            let softBreaks = try blocks(softBreaksPage, [
                (.paragraph, "Абзац в три строки:\nвторая строка после Shift+Enter\nи третья.", 0, false),
                (.bulletItem, "Пункт списка\nс продолжением на второй строке", 0, false),
                (.numberedItem, "Нумерованный пункт\nв две строки", 0, false),
                (.numberedItem, "Второй пункт", 0, false),
                (.checkbox, "Задача\nс пояснением ниже", 0, false),
                (.paragraph, "Абзац в одну строку.", 0, false),
            ])

            let nestedLists = try page("Вложенные списки", icon: "🧩")
            let nestedListIds = try blocks(nestedLists, [
                (.heading2, "Маркированный", 0, false),
                (.bulletItem, "Первый уровень", 0, false), (.bulletItem, "Второй уровень", 1, false),
                (.bulletItem, "Третий уровень", 2, false), (.bulletItem, "Снова первый", 0, false),
                (.heading2, "Нумерованный", 0, false),
                (.numberedItem, "Первый уровень", 0, false), (.numberedItem, "Второй уровень", 1, false),
                (.numberedItem, "Третий уровень", 2, false), (.numberedItem, "Ещё третий", 2, false),
                (.numberedItem, "Снова первый", 0, false),
                (.heading2, "Чекбоксы", 0, false),
                (.checkbox, "Задача первого уровня", 0, false), (.checkbox, "Выполненная второго уровня", 1, true),
                (.checkbox, "Задача третьего уровня", 2, false), (.checkbox, "Выполненная третьего уровня", 2, true),
                (.checkbox, "Выполненная первого уровня", 0, true),
            ])

            let emptyPage = try page("Пустая страница")
            _ = try blocks(emptyPage, [(.paragraph, "", 0, false)])
            let untitledPage = try page("")
            _ = try blocks(untitledPage, [(.paragraph, "", 0, false)])

            let projects = try page("Проекты", icon: "📁")
            let work = try page("Работа над приложением заметок для macOS", parent: projects)
            let report = try page("Квартальный отчёт о ходе разработки и планы на следующий период", icon: "📊", parent: work)
            let deepPage = try page("Черновик таблиц с замерами скорости набора текста", parent: report)
            for id in [projects, work, report] { _ = try blocks(id, [(.paragraph, "Страница ветки четырёх уровней.", 0, false)]) }
            _ = try blocks(deepPage, [(.paragraph, "Страница четвёртого уровня с длинным путём.", 0, false)])
            _ = try page("Сайт", parent: projects)

            let longTitlePage = try page("Очень длинное название страницы, которое точно не помещается в боковую панель целиком")
            let archive = try page("Архив", icon: "📦")
            for year in ["2025", "2024"] { _ = try page(year, parent: archive) }
            let notesPage = try page("Заметки на неделю", icon: "📅")
            let notesBlock = try blocks(notesPage, [(.paragraph, "Купить молоко", 0, false)])[0]

            let conflictPage = try page("План поездки", icon: "🧳")
            let conflictBlocks = try blocks(conflictPage, [
                (.heading2, "Что взять", 0, false),
                (.paragraph, "Паспорт, зарядку и тёплую куртку — вечером там холодно.", 0, false),
                (.paragraph, "Билеты уже в почте.", 0, false),
            ])
            try transaction.recordConflict(blockId: conflictBlocks[1],
                                           localVersion: InlineText("Паспорт, зарядку и тёплую куртку — вечером там холодно."),
                                           remoteVersion: InlineText("Паспорт, зарядку, зонт и куртку."),
                                           remoteDeviceName: "MacBook Air")

            let oldNotes = try page("Старые заметки", trashed: true)
            _ = try page("Список покупок", parent: oldNotes)
            _ = try page("Удалённая страница с очень длинным названием, которое обрезается в корзине", trashed: true)
            _ = try page("Цели на год", icon: "🎯", trashed: true)

            return GalleryLibrary(sample: sample, blockKindPages: blockKindPages, nestedLists: nestedLists,
                                  softBreaksPage: softBreaksPage, softBreaks: softBreaks,
                                  nestedListGroup: nestedListIds[1], emptyPage: emptyPage,
                                  untitledPage: untitledPage, projects: projects, projectBranch: [projects, work, report],
                                  deepPage: deepPage, longTitlePage: longTitlePage, archive: archive,
                                  notesPage: notesPage, notesBlock: notesBlock,
                                  conflictPage: conflictPage, conflictBlock: conflictBlocks[1])
        }
    }

    private static func pageTitle(of kind: BlockKind) -> String {
        switch kind {
        case .paragraph: "Абзац"
        case .heading1: "Заголовок 1"
        case .heading2: "Заголовок 2"
        case .heading3: "Заголовок 3"
        case .bulletItem: "Маркированный список"
        case .numberedItem: "Нумерованный список"
        case .checkbox: "Чекбокс"
        case .pageLink: "Подстраница"
        }
    }
}
