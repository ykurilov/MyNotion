import Foundation
import NotionAPI
import Proofreading

/// Ключи DeepSeek, Notion и OpenRouter для синхронизации: та же связка ключей, что у «Исправить ошибки», картинок
/// из Notion и ИИ-агента, поэтому пришедший с другого устройства ключ сразу виден и настройкам, и кнопкам. Записать ключ можно только
/// отсюда — через `ServiceKeySync`, с меткой для других устройств.
public struct KeychainServiceKeys: ServiceKeyStore {
    let deepSeek: ProofreadingKeychain
    let notion: NotionKeychain
    let openRouter: ProofreadingKeychain

    public init(deepSeek: ProofreadingKeychain, notion: NotionKeychain, openRouter: ProofreadingKeychain) {
        self.deepSeek = deepSeek
        self.notion = notion
        self.openRouter = openRouter
    }

    public var names: [String] { ServiceKeyName.all }

    public func value(for name: String) throws -> String? {
        switch name {
        case ServiceKeyName.deepSeek: try deepSeek.storedKey()
        case ServiceKeyName.notion: try notion.storedKey()
        case ServiceKeyName.openRouter: try openRouter.storedKey()
        default: nil
        }
    }

    public func setValue(_ value: String?, for name: String) throws {
        switch name {
        case ServiceKeyName.deepSeek: try deepSeek.replaceKey(value)
        case ServiceKeyName.notion: try notion.replaceKey(value)
        case ServiceKeyName.openRouter: try openRouter.replaceKey(value)
        default: break
        }
    }
}
