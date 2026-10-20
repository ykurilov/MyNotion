import Foundation
import NotesCore
import Observation

/// Что переносится через окно «Переместить в…»: страница целиком или блоки страницы.
public enum PagePickerSubject: Equatable, Sendable {
    case page(UUID)
    case blocks(fromPage: UUID)
}

/// Куда: внутрь страницы или на верхний уровень «Страниц» (только для страницы).
public enum PagePickerTarget: Equatable, Sendable {
    case page(UUID)
    case topLevel
}

/// Строка окна.
public struct PagePickerRow: Identifiable, Equatable, Sendable {
    public enum Section: Sendable { case recent, pages, results }

    public let section: Section
    public let target: PagePickerTarget
    public let title: String
    public let icon: String?
    /// Путь предков через « / » — у строк выдачи поиска.
    public let path: String?
    /// Сдвиг строки дерева.
    public let depth: Int
    public let hasChildren: Bool
    public let isExpanded: Bool
    /// Серая строка не выбирается.
    public let isAvailable: Bool

    public var id: String {
        switch target {
        case .page(let id): "\(section)-\(id.uuidString)"
        case .topLevel: "\(section)-top"
        }
    }
}

/// Клавиши окна.
public enum PagePickerKey: Sendable {
    case up, down, left, right, enter, escape
}

/// Модель окна «Переместить в…» (research R9): без запроса — до 5 недавних, ниже дерево «Страницы» с раскрытием;
/// с запросом — выдача поиска 001. Недоступны: для страницы — она сама и её ветка, для блоков — исходная страница;
/// корзины нет (её нет в дереве). Клавиатура: ↑↓ по доступным строкам, → раскрыть, ← свернуть, Enter выбрать, Esc закрыть.
@MainActor
@Observable
public final class PagePickerModel {
    public static let recentLimit = 5
    public static let topLevelTitle = "Страницы — верхний уровень"

    public let subject: PagePickerSubject
    @ObservationIgnored private let tree: PageTreeSnapshot
    @ObservationIgnored private let recentPages: [Page]
    @ObservationIgnored private let search: (String) -> [UUID]

    public var query = "" {
        didSet { rebuild() }
    }
    public private(set) var rows: [PagePickerRow] = []
    public private(set) var selectedIndex: Int?
    public private(set) var expandedPageIds: Set<UUID> = []

    @ObservationIgnored public var onChoose: ((PagePickerTarget) -> Void)?
    @ObservationIgnored public var onDismiss: (() -> Void)?

    /// `recentPages` — недавние по порядку (лишние и из корзины отбрасываются); `search` — id страниц выдачи по запросу.
    public init(subject: PagePickerSubject, tree: PageTreeSnapshot, recentPages: [Page], search: @escaping (String) -> [UUID]) {
        self.subject = subject
        self.tree = tree
        self.recentPages = recentPages
        self.search = search
        rebuild()
    }

    public var selectedRow: PagePickerRow? { selectedIndex.map { rows[$0] } }

    public var placeholder: String { "Переместить в…" }

    // MARK: Действия

    public func toggleExpanded(_ pageId: UUID) {
        if expandedPageIds.remove(pageId) == nil { expandedPageIds.insert(pageId) }
        rebuild(keepingSelection: true)
    }

    public func select(_ index: Int) {
        guard rows.indices.contains(index), rows[index].isAvailable else { return }
        selectedIndex = index
    }

    /// Щелчок или Enter: недоступная строка ничего не выбирает.
    public func choose(at index: Int) {
        guard rows.indices.contains(index), rows[index].isAvailable else { return }
        onChoose?(rows[index].target)
    }

    /// Клавиша: `true` — окно её обработало.
    @discardableResult
    public func handle(_ key: PagePickerKey) -> Bool {
        switch key {
        case .up: moveSelection(by: -1)
        case .down: moveSelection(by: 1)
        case .right, .left:
            guard let row = selectedRow, case .page(let id) = row.target, row.hasChildren, row.isExpanded == (key == .left) else { return true }
            toggleExpanded(id)
        case .enter:
            if let selectedIndex { choose(at: selectedIndex) }
        case .escape:
            onDismiss?()
        }
        return true
    }

    private func moveSelection(by step: Int) {
        guard let current = selectedIndex else { return }
        var index = current + step
        while rows.indices.contains(index) {
            if rows[index].isAvailable {
                selectedIndex = index
                return
            }
            index += step
        }
    }

    // MARK: Строки

    private func rebuild(keepingSelection: Bool = false) {
        let selectedId = keepingSelection ? selectedRow?.id : nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = trimmed.isEmpty ? recentRows() + treeRows() : resultRows(trimmed)
        selectedIndex = selectedId.flatMap { id in rows.firstIndex { $0.id == id } } ?? rows.firstIndex(where: \.isAvailable)
    }

    private func recentRows() -> [PagePickerRow] {
        recentPages.lazy.compactMap { [tree] in tree.page($0.id) }.prefix(Self.recentLimit).map { page in
            row(page, section: .recent, depth: 0, expandable: false)
        }
    }

    private func treeRows() -> [PagePickerRow] {
        var rows: [PagePickerRow] = []
        if case .page = subject {
            rows.append(PagePickerRow(section: .pages, target: .topLevel, title: Self.topLevelTitle, icon: nil, path: nil, depth: 0,
                                      hasChildren: false, isExpanded: false, isAvailable: true))
        }
        func appendChildren(of parentId: UUID?, depth: Int) {
            for page in tree.children(of: parentId) {
                rows.append(row(page, section: .pages, depth: depth, expandable: true))
                if expandedPageIds.contains(page.id) { appendChildren(of: page.id, depth: depth + 1) }
            }
        }
        appendChildren(of: nil, depth: 0)
        return rows
    }

    private func resultRows(_ query: String) -> [PagePickerRow] {
        search(query).compactMap { tree.page($0) }.map { page in
            let path = tree.ancestors(of: page.id).map(\.displayTitle).joined(separator: " / ")
            return row(page, section: .results, depth: 0, expandable: false, path: path)
        }
    }

    private func row(_ page: Page, section: PagePickerRow.Section, depth: Int, expandable: Bool, path: String? = nil) -> PagePickerRow {
        let hasChildren = expandable && !tree.children(of: page.id).isEmpty
        return PagePickerRow(section: section, target: .page(page.id), title: page.displayTitle, icon: page.icon, path: path, depth: depth,
                             hasChildren: hasChildren, isExpanded: hasChildren && expandedPageIds.contains(page.id),
                             isAvailable: isAvailable(page.id))
    }

    private func isAvailable(_ pageId: UUID) -> Bool {
        switch subject {
        case .page(let moved): !tree.isPage(pageId, insideBranchOf: moved)
        case .blocks(let source): pageId != source
        }
    }
}
