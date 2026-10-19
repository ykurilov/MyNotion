import NotesCore

extension BlockDraft {
    /// Смена типа блока: свойства нового типа по умолчанию (иконка выноски), прежние ключи остаются; серый фон выноски
    /// появляется у блока без цвета и уходит вместе с выноской, если его не меняли.
    mutating func adoptDefaults(of kind: BlockKind, from block: Block) {
        var props = block.props
        for (key, value) in BlockProps.defaults(for: kind).values where props.values[key] == nil { props.values[key] = value }
        self.props = props
        let oldDefault = BlockColor.defaults(for: block.kind)
        var color = block.color
        if !oldDefault.isNone, color == oldDefault { color = .none }
        if color.isNone { color = .defaults(for: kind) }
        self.color = color
    }
}
