import Foundation
import NotionAPI
import Proofreading
import Sync

/// Ключи DeepSeek и Notion для синхронизации: та же связка ключей, что у «Исправить ошибки» и картинок из Notion,
/// поэтому пришедший с другого устройства ключ сразу виден и настройкам, и кнопкам.
struct AppServiceKeys: ServiceKeyStore {
    let deepSeek: ProofreadingKeychain
    let notion: NotionKeychain

    var names: [String] { ServiceKeyName.all }

    func value(for name: String) throws -> String? {
        switch name {
        case ServiceKeyName.deepSeek: try deepSeek.storedKey()
        case ServiceKeyName.notion: try notion.storedKey()
        default: nil
        }
    }

    func setValue(_ value: String?, for name: String) throws {
        switch name {
        case ServiceKeyName.deepSeek: try deepSeek.replaceKey(value)
        case ServiceKeyName.notion: try notion.replaceKey(value)
        default: break
        }
    }
}
