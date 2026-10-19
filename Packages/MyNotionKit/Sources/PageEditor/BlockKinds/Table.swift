import NotesCore

extension BlockKindDescriptor {
    // Наполняет этап US6 (tasks.md): таблица в потоке страницы; строки, столбцы и ячейки — в её потоках.
    static let table = BlockKindDescriptor.notYetBuilt(.table)
    static let tableRow = BlockKindDescriptor.notYetBuilt(.tableRow)
    static let tableColumn = BlockKindDescriptor.notYetBuilt(.tableColumn)
    static let tableCell = BlockKindDescriptor.notYetBuilt(.tableCell)
}
