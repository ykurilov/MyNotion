import ControlProtocol
import Foundation
import NotesCore

/// Указатель блока — только id (строкой из `page read --format json`, research R10). С `inPage` блок обязан быть
/// этой страницы: иначе `wrong_page` с настоящей страницей блока.
@MainActor
public struct BlockLocator {
    let store: NotesStore

    public init(store: NotesStore) {
        self.store = store
    }

    public func resolve(_ text: String, inPage pageId: UUID? = nil) throws(ControlError) -> Block {
        let pointer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = UUID(uuidString: pointer) else {
            throw ControlError(.invalidValue, "Блок указывается id, а не «\(pointer)»",
                               hint: "id блоков: mynotion page read <стр> --format json", details: ["block": .string(pointer)])
        }
        let found: Block?
        do {
            found = try store.block(id)
        } catch {
            throw ControlError(.internal, "Не прочитать блок: \(error.localizedDescription)")
        }
        guard let block = found else {
            throw ControlError(.blockNotFound, "Блока \(id.uuidString.lowercased()) нет",
                               hint: "id блоков: mynotion page read <стр> --format json", details: ["block": .string(id.uuidString.lowercased())])
        }
        if let pageId, block.pageId != pageId {
            throw ControlError(.wrongPage, "Блок \(id.uuidString.lowercased()) — с другой страницы",
                               hint: "Укажите его страницу: \(block.pageId.uuidString.lowercased())",
                               details: ["pageId": .string(block.pageId.uuidString.lowercased()), "block": .string(id.uuidString.lowercased())])
        }
        return block
    }
}
