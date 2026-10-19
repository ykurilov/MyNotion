import NotesCore

extension BlockKindDescriptor {
    // Наполняет этап US6 (tasks.md): колонки в потоке страницы, у каждой колонки — свой поток блоков.
    static let columnList = BlockKindDescriptor.notYetBuilt(.columnList)
    static let column = BlockKindDescriptor.notYetBuilt(.column)
}
