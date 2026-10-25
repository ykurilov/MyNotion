import Foundation

/// Правки по словам для окна «Исправить ошибки»: что было — зачёркнуто, что стало — выделено.
public struct WordDiffPiece: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case same
        case removed
        case inserted
    }

    public let kind: Kind
    public let text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum WordDiff {
    /// Куски по порядку; в каждой замене сначала удалённое, потом вставленное. Соседние куски одного вида слиты.
    public static func pieces(from old: String, to new: String) -> [WordDiffPiece] {
        let source = tokens(of: old), target = tokens(of: new)
        let difference = target.difference(from: source)
        var removed = IndexSet(), inserted = IndexSet()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var pieces: [WordDiffPiece] = []
        var removedRun = "", insertedRun = ""
        func flush() {
            if !removedRun.isEmpty { append(.removed, removedRun) }
            if !insertedRun.isEmpty { append(.inserted, insertedRun) }
            removedRun = ""
            insertedRun = ""
        }
        func append(_ kind: WordDiffPiece.Kind, _ text: String) {
            if let last = pieces.last, last.kind == kind {
                pieces[pieces.count - 1] = WordDiffPiece(kind, last.text + text)
            } else {
                pieces.append(WordDiffPiece(kind, text))
            }
        }
        var i = 0, j = 0
        while i < source.count || j < target.count {
            if i < source.count, removed.contains(i) { removedRun += source[i]; i += 1; continue }
            if j < target.count, inserted.contains(j) { insertedRun += target[j]; j += 1; continue }
            flush()
            append(.same, source[i])
            i += 1
            j += 1
        }
        flush()
        return pieces
    }

    /// Слова (буквы, цифры, дефис и апостроф внутри), пробелы подряд и каждый знак препинания — отдельно.
    static func tokens(of text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentIsWord = false, currentIsSpace = false
        func push() {
            if !current.isEmpty { tokens.append(current) }
            current = ""
        }
        for character in text {
            let isWord = character.isLetter || character.isNumber || character == "⟦" || character == "⟧"
                || ((character == "-" || character == "'" || character == "’") && currentIsWord)
            let isSpace = character.isWhitespace
            if isWord, currentIsWord { current.append(character); continue }
            if isSpace, currentIsSpace { current.append(character); continue }
            push()
            current.append(character)
            currentIsWord = isWord
            currentIsSpace = isSpace
        }
        push()
        return tokens
    }
}
