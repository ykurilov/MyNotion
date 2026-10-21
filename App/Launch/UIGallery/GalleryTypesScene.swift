import AppKit
import DatabaseGrid
import DatabaseViewBar
import Databases
import NotesCore
import UIGallery

/// Типы US2 в галерее (T074): база «Типы» — выбор с 10 цветами, теги, статус, сроки с концом и напоминанием, файлы с
/// картинкой и ссылкой, число полосой и кольцом; окна ячеек и панели «Изменить свойство» открываются настоящими
/// щелчками сетки. Сверка — `notion-select-*.png`, `notion-status-cell-popup.png`, `notion-edit-property-*.png`,
/// `notion-date-format-options.png`, `notion-number-show-as-bar.png`.
@MainActor
enum GalleryTypesScene {
    private static var menus: PropertyMenuPresenter?

    static func handles(_ kind: GalleryDatabases) -> Bool {
        [.typeSelectPicker, .typeMultiSelectPicker, .typeStatusPicker, .typeOptionMenu, .typeDatePicker, .typeDateFormats, .typeFilesPopup,
         .typeSelectSettings, .typeStatusSettings, .typeNumberSettings, .typeChipsAndMeters].contains(kind)
    }

    /// Колонки базы «Типы» по местам в виде.
    private enum Column: Int { case select = 1, tags, status, due, files, progress, score }

    static func show(_ kind: GalleryDatabases, model: MainWindowModel, window: NSWindow) async -> String? {
        let databaseId: UUID
        do { databaseId = try makeDatabase(model: model) } catch { return "база «Типы» не записалась: \(error)" }
        model.library.reloadTree()
        model.select(databaseId)
        await settle()
        guard let table = GalleryDatabasesScene.find(DatabaseTableView.self, in: window.contentView) else { return "таблица не показана" }
        let grid = table.grid
        let controller = table.controller
        func open(_ column: Column, row: Int = 0) async {
            grid.select(CellPosition(row: row, column: column.rawValue))
            grid.beginEditing()
            await settle()
        }
        func editProperty(_ column: Column) {
            let presenter = PropertyMenuPresenter(store: model.store, operations: model.databaseOperations, databaseId: controller.databaseId,
                                                  viewId: controller.viewId)
            menus = presenter
            presenter.showEditProperty(controller.content.columns[column.rawValue].property.id, in: table)
        }
        switch kind {
        case .typeSelectPicker: await open(.select)
        case .typeMultiSelectPicker:
            await open(.tags)
            CellPopupGallery.search("Ново")
        case .typeStatusPicker: await open(.status)
        case .typeOptionMenu:
            await open(.select)
            CellPopupGallery.openOptionMenu()
        case .typeDatePicker: await open(.due)
        case .typeDateFormats:
            await open(.due)
            CellPopupGallery.openDateFormats()
        case .typeFilesPopup: await open(.files)
        case .typeSelectSettings: editProperty(.select)
        case .typeStatusSettings: editProperty(.status)
        case .typeNumberSettings: editProperty(.progress)
        default: window.makeFirstResponder(nil)
        }
        await settle()
        return nil
    }

    static func tearDown() {
        CellPopupGallery.close()
        menus?.close()
        menus = nil
    }

    private static func settle() async { try? await Task.sleep(for: .milliseconds(500)) }

    /// База «Типы»: 8 строк; у «Типа» — 10 вариантов всех цветов Notion.
    private static func makeDatabase(model: MainWindowModel) throws -> UUID {
        let store = model.store
        let operations = DatabaseOperations(store: store)
        let created = try operations.createDatabase(in: nil, isInline: false, title: "Типы")
        let id = created.databaseId
        let select = try operations.addProperty(to: id, name: "Тип", kind: .select)
        let tags = try operations.addProperty(to: id, name: "Теги", kind: .multiSelect)
        let status = try operations.addProperty(to: id, name: "Статус", kind: .status)
        let due = try operations.addProperty(to: id, name: "Срок", kind: .date, config: ["timeFormat": "h24"])
        let files = try operations.addProperty(to: id, name: "Файлы", kind: .files)
        let progress = try operations.addProperty(to: id, name: "Готовность", kind: .number,
                                                  config: ["format": "percent", "showAs": ["style": "bar", "color": "green", "divideBy": 1, "showNumber": true]])
        let score = try operations.addProperty(to: id, name: "Оценка", kind: .number,
                                               config: ["showAs": ["style": "ring", "color": "blue", "divideBy": 10, "showNumber": true]])
        let names = ["Обычный", "Заметка", "Идея", "Покупка", "Звонок", "Встреча", "Задача", "Ревью", "Личное", "Баг"]
        let options = try zip(names, OptionColor.allCases).map { try operations.createOption(in: select.id, named: $0, color: $1) }
        let tagOptions = try [("Срочно", OptionColor.red), ("Потом", .gray), ("Дом", .green), ("Работа", .blue)]
            .map { try operations.createOption(in: tags.id, named: $0.0, color: $0.1) }
        let statusOptions = try DatabaseCatalog.read(id, in: store).options[status.id] ?? []
        let image = NSImage(size: NSSize(width: 64, height: 48), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            NSColor.systemYellow.setFill()
            NSBezierPath(ovalIn: NSRect(x: 36, y: 24, width: 18, height: 18)).fill()
            return true
        }
        let png = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]) ?? Data()
        let picture = try model.library.attachments.importData(png, name: "Схема.png", contentType: "public.png")
        let report = try model.library.attachments.importData(Data("отчёт".utf8), name: "Отчёт.pdf", contentType: "com.adobe.pdf")
        let titles = ["Сдать отчёт", "Купить молоко", "Позвонить в банк", "Ремонт велосипеда", "Статья для клуба", "Запись к врачу",
                      "Обновить сайт", "Выбрать подарок", "Разобрать почту", "Отпуск"]
        for (index, title) in titles.enumerated() {
            let row = try operations.addRow(to: id, in: created.viewId, at: .bottom, title: title)
            try operations.setCell(rowId: row, propertyId: select.id, value: .string(options[index].id.uuidString.lowercased()))
            let chosenTags = tagOptions.enumerated().filter { ($0.offset + index) % 3 == 0 }.map { JSONValue.string($0.element.id.uuidString.lowercased()) }
            if !chosenTags.isEmpty { try operations.setCell(rowId: row, propertyId: tags.id, value: .array(chosenTags)) }
            if !statusOptions.isEmpty {
                try operations.setCell(rowId: row, propertyId: status.id, value: .string(statusOptions[index % statusOptions.count].id.uuidString.lowercased()))
            }
            var date: JSONValue = ["start": .string(String(format: "2026-10-%02d", 20 + index)), "hasTime": false, "timeZone": "Europe/Moscow"]
            if index == 0 {
                date = ["start": "2026-10-21T15:00", "end": "2026-10-23T18:30", "hasTime": true, "timeZone": "Europe/Moscow", "reminder": "day1"]
            }
            try operations.setCell(rowId: row, propertyId: due.id, value: date)
            if index < 2 {
                try operations.addFiles([.file(picture), .file(report), .link(url: "https://notion.so/help", name: "help")], rowId: row, propertyId: files.id)
            }
            try operations.setCell(rowId: row, propertyId: progress.id, value: .number(Double(index) / 9))
            try operations.setCell(rowId: row, propertyId: score.id, value: .number(Double(index + 1)))
        }
        for property in [select, tags, status, files, progress, score] { try operations.setColumnWidth(property.id, in: created.viewId, to: 170) }
        try operations.setColumnWidth(due.id, in: created.viewId, to: 260)
        return id
    }
}
