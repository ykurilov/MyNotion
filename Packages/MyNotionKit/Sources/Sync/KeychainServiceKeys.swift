import Foundation
import NotionAPI
import Proofreading

/// Ключи DeepSeek и Notion для синхронизации: та же связка ключей, что у «Исправить ошибки» и картинок из Notion,
/// поэтому пришедший с другого устройства ключ сразу виден и настройкам, и кнопкам. Записать ключ можно только
/// отсюда — через `ServiceKeySync`, с меткой для других устройств.
public struct KeychainServiceKeys: ServiceKeyStore {
    let deepSeek: ProofreadingKeychain
    let notion: NotionKeychain

    public init(deepSeek: ProofreadingKeychain, notion: NotionKeychain) {
        self.deepSeek = deepSeek
        self.notion = notion
    }

    public var names: [String] { ServiceKeyName.all }

    public func value(for name: String) throws -> String? {
        switch name {
        case ServiceKeyName.deepSeek: try deepSeek.storedKey()
        case ServiceKeyName.notion: try notion.storedKey()
        default: nil
        }
    }

    public func setValue(_ value: String?, for name: String) throws {
        switch name {
        case ServiceKeyName.deepSeek: try deepSeek.replaceKey(value)
        case ServiceKeyName.notion: try notion.replaceKey(value)
        default: break
        }
    }
}
