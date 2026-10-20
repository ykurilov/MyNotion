import Foundation
import NotesCore

/// Что редактор просит у владельца дерева, когда выбрали «Страница» (как «Page» у Notion 7.39).
public enum SubpageRequest: Equatable, Sendable {
    /// «/» → «Страница»: создать подстраницу со ссылкой у блока и сразу открыть её, курсор — в названии.
    case createAndOpen(SubpageLinkPlacement)
    /// «Преобразовать в → Страница»: блок становится ссылкой на подстраницу с его текстом в названии; без перехода.
    case turnInto(blockId: UUID)
}
