import CoreServices
import Foundation

/// Пометка карантина macOS (`com.apple.quarantine`) на копиях, пришедших извне: сеть, другой Mac, импорт. Открытие
/// такого файла проходит проверку Gatekeeper, как у скачанного браузером.
public enum FileQuarantine {
    static let attribute = "com.apple.quarantine"

    public static func mark(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "MyNotion",
                                       kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
        try? url.setResourceValues(values)
    }

    /// Копия из Finder — с той же пометкой, что у исходника: браузер ставит её на скачанное, а копия кусками её теряет.
    static func carryOver(from source: URL, to destination: URL) {
        let size = getxattr(source.path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(source.path, attribute, &value, size, 0, 0) == size else { return }
        setxattr(destination.path, attribute, value, size, 0, 0)
    }
}
