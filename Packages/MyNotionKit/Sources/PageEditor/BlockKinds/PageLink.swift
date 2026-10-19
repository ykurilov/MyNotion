import NotesCore

extension BlockKindDescriptor {
    /// Подстраница создаётся в боковом дереве (US2 001), в меню «/» её нет. Текста у блока нет: строку рисует фрагмент.
    static let pageLink = BlockKindDescriptor(kind: .pageLink, marker: .pageLink)
}
