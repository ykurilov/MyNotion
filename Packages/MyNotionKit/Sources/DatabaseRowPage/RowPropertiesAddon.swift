import AppKit
import Databases
import Foundation
import NotesCore
import PageEditor

/// Свойства строки в месте «под названием» шапки страницы (contracts/database-ui.md, «Страница строки»), над строкой
/// обратных ссылок 003. Значения пишет через операции баз окна (`setCell` — шаг ⌘Z), перечитывает по
/// `DatabaseOperations.didChange` — правка в таблице, в другом окне или с другого Mac видна сразу.
@MainActor
public final class RowPropertiesAddon: PageHeaderAddon {
    /// Свойства — выше обратных ссылок (у них место по умолчанию, 0).
    public static let underTitleOrder = -1
    /// Название в панели сбоку: 33 pt против 53 pt на странице у Notion.
    public static let compactTitleFactor: CGFloat = 0.62

    private let rowId: UUID
    private weak var operations: DatabaseOperations?
    private weak var textView: PageTextView?
    public private(set) var view: RowPropertiesView?
    /// «+ Добавить свойство»: окно типов под кнопкой (делает хозяин).
    public var onAddProperty: ((NSView) -> Void)?
    /// Значение с окном правки (выбор, статус, дата, файлы, связь — US2, US4).
    public var onOpenEditor: ((UUID, NSView) -> Void)?
    /// Название мельче обычного: строка открыта сбоку.
    public var usesCompactTitle = false
    /// Запись не удалась.
    public var onError: ((any Error) -> Void)?
    nonisolated(unsafe) private var changeObserver: NSObjectProtocol?

    public init(rowId: UUID, operations: DatabaseOperations) {
        self.rowId = rowId
        self.operations = operations
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    public func install(in textView: PageTextView) {
        self.textView = textView
        if usesCompactTitle { textView.titleSizeFactor = Self.compactTitleFactor }
        // Одно чтение строки и схемы — до показа страницы: свойства не «впрыгивают» после открытия.
        guard let store = operations?.store, let page = try? RowPage.read(rowId, in: store) else { return }
        let view = RowPropertiesView(page: page)
        view.onCommit = { [weak self] propertyId, value in self?.write(propertyId, value) }
        view.onAddProperty = { [weak self] anchor in self?.onAddProperty?(anchor) }
        view.onOpenEditor = { [weak self] propertyId, anchor in self?.onOpenEditor?(propertyId, anchor) }
        view.onHeightChange = { [weak self, weak view] height in
            guard let self, let view else { return }
            self.textView?.setUnderTitle(view, height: height, order: Self.underTitleOrder)
        }
        self.view = view
        textView.setUnderTitle(view, height: view.fittingHeight, order: Self.underTitleOrder)
        let rowId = rowId
        let databaseId = page.databaseId
        changeObserver = NotificationCenter.default.addObserver(forName: DatabaseOperations.didChange, object: nil, queue: .main) { [weak self] note in
            let touched = note.userInfo?[DatabaseOperations.touchedKey] as? Set<UUID>
            guard touched.map({ $0.contains(rowId) || $0.contains(databaseId) }) ?? true else { return }
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    public func pageDidChange(_ page: Page, in textView: PageTextView) {}

    /// Перечитать значения и схему. Строку убрали из базы (перенесли, стёрли) — свойства уходят.
    public func reload() {
        guard let view, let store = operations?.store else { return }
        guard let page = try? RowPage.read(rowId, in: store) else {
            textView?.setUnderTitle(nil, height: 0, order: Self.underTitleOrder)
            self.view = nil
            return
        }
        view.show(page)
    }

    private func write(_ propertyId: UUID, _ value: JSONValue?) {
        do {
            try operations?.setCell(rowId: rowId, propertyId: propertyId, value: value)
        } catch {
            onError?(error)
        }
    }
}
