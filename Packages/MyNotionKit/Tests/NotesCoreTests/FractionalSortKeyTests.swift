import Testing
@testable import NotesCore

@Suite("Дробный ключ порядка")
struct FractionalSortKeyTests {
    @Test("Ключ между двумя соседями лежит строго между ними")
    func keyBetweenNeighbours() {
        let first = FractionalSortKey.between(nil, nil)
        let last = FractionalSortKey.between(first, nil)
        let middle = FractionalSortKey.between(first, last)

        #expect(first < middle)
        #expect(middle < last)
    }

    @Test("Ключ в начало меньше первого, в конец — больше последнего")
    func keysAtEdges() {
        let only = FractionalSortKey.between(nil, nil)
        let atStart = FractionalSortKey.between(nil, only)
        let atEnd = FractionalSortKey.between(only, nil)

        #expect(atStart < only)
        #expect(only < atEnd)
    }

    @Test("Порядок ключей совпадает с побайтовым порядком строк, как в SQLite")
    func orderMatchesBytewiseStringOrder() {
        var keys = [FractionalSortKey.between(nil, nil)]
        for _ in 0..<300 {
            keys.append(.between(keys.last, nil))
            keys.insert(.between(nil, keys.first), at: 0)
            let i = Int.random(in: 0..<(keys.count - 1))
            keys.insert(.between(keys[i], keys[i + 1]), at: i + 1)
        }

        let neighbours = Array(zip(keys, keys.dropFirst()))
        #expect(neighbours.allSatisfy { $0 < $1 })
        #expect(neighbours.allSatisfy { $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8) })
    }

    @Test("10 000 вставок подряд в одно место — без перенумерации соседей")
    func tenThousandInsertsInOnePlace() {
        let left = FractionalSortKey.between(nil, nil)
        let right = FractionalSortKey.between(left, nil)

        // Каждый новый блок встаёт сразу после левого соседа — перед предыдущим новым.
        var newest = right
        var inserted: [FractionalSortKey] = []
        var everyKeyBetweenNeighbours = true
        for _ in 0..<10_000 {
            let key = FractionalSortKey.between(left, newest)
            everyKeyBetweenNeighbours = everyKeyBetweenNeighbours && left < key && key < newest
            inserted.append(key)
            newest = key
        }

        // Каждый новый блок встаёт после предыдущего нового — как при наборе абзац за абзацем.
        var previous = left
        for _ in 0..<10_000 {
            let key = FractionalSortKey.between(previous, right)
            everyKeyBetweenNeighbours = everyKeyBetweenNeighbours && previous < key && key < right
            previous = key
        }

        #expect(everyKeyBetweenNeighbours)
        #expect(Set(inserted).count == inserted.count)
        #expect(left == FractionalSortKey.between(nil, nil))
        // Ключ растёт примерно на символ за 6 вставок в одно место, а не на символ за вставку.
        #expect(inserted.map(\.rawValue.count).max()! < 2_500)
    }

    @Test("Ключи в конец растут медленно — страница набирается сверху вниз")
    func appendingKeepsKeysShort() {
        var last = FractionalSortKey.between(nil, nil)
        for _ in 0..<1_000 {
            last = .between(last, nil)
        }
        #expect(last.rawValue.count <= 20)
    }
}
