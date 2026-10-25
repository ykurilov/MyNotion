import Foundation

/// Где сокет команд (research R1): рядом с базой, `control.sock`. Путь длиннее предела `sun_path` — в `$TMPDIR` по хэшу
/// папки базы. Нужен и приложению (где слушать), и клиенту (куда стучаться).
public enum ControlSocketPath {
    public static let fileName = "control.sock"
    /// `sun_path` — 104 байта с нулём в конце; запас под нуль и разницу систем.
    public static let maxPathBytes = 100

    /// Сокет базы по умолчанию: `~/Library/Application Support/MyNotion/control.sock`.
    public static var standard: String {
        path(forDatabaseFolder: URL.applicationSupportDirectory.appendingPathComponent("MyNotion", isDirectory: true))
    }

    /// Сокет для базы в `folder` (`--database <путь>` — папка файла базы).
    public static func path(forDatabaseFolder folder: URL, temporaryDirectory: String = NSTemporaryDirectory()) -> String {
        let nextToDatabase = folder.appendingPathComponent(fileName).path
        guard nextToDatabase.utf8.count > maxPathBytes else { return nextToDatabase }
        let temporary = URL(fileURLWithPath: temporaryDirectory, isDirectory: true)
            .appendingPathComponent("mynotion-\(hash(of: folder.standardizedFileURL.path)).sock").path
        return temporary
    }

    /// 8 шестнадцатеричных знаков FNV-1a: одинаковы при каждом запуске, в отличие от `hashValue`.
    static func hash(of text: String) -> String {
        var value: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            value ^= UInt32(byte)
            value = value &* 16_777_619
        }
        return String(format: "%08x", value)
    }
}
