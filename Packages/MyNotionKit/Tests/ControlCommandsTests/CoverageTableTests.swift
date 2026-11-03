import ControlProtocol
import Foundation
import Testing
@testable import ControlCommands

/// Охват управления (SC-408): у каждой операции окна есть команда, а каталог не обещает команд без обработчика.
/// Источник охвата — `specs/005-cli-control/contracts/coverage.md`; новая публичная операция в `PageTreeOperations`,
/// `DatabaseOperations` или `WindowTabs` без строки там делает тест красным.
@Suite struct CoverageTableTests {
    static let operationClasses = ["PageTreeOperations", "DatabaseOperations", "WindowTabs"]

    /// Папка проекта: этот файл лежит в `Packages/MyNotionKit/Tests/ControlCommandsTests/`.
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sources = root.appendingPathComponent("Packages/MyNotionKit/Sources")

    /// Публичные методы класса: имена из `public func` во всех файлах его типа и расширений.
    static func publicMethods(of operationClass: String) throws -> Set<String> {
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent.hasPrefix(operationClass) } ?? []
        #expect(!files.isEmpty, "Не нашли файлы \(operationClass) в \(sources.path)")
        let declaration = try NSRegularExpression(pattern: #"^\s*public\s+(?:@\w+\s+)*(?:static\s+)?func\s+([A-Za-z_]\w*)"#,
                                                  options: .anchorsMatchLines)
        var names: Set<String> = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in declaration.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                names.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        return names
    }

    /// Названия из кода в `coverage.md`: в первом столбце таблицы и в разделах «не входит». Запись `Класс.имя` относится
    /// к классу; запись без класса — ко всем. Скобки с аргументами отбрасываются, `a/b/c` после `Класс.` — один класс.
    struct Mentions {
        var qualified: Set<String> = []
        var unqualified: Set<String> = []

        func covers(_ name: String, in operationClass: String, uniqueName: Bool) -> Bool {
            qualified.contains("\(operationClass).\(name)") || (uniqueName && unqualified.contains(name))
        }
    }

    static func mentions() throws -> Mentions {
        let text = try String(contentsOf: root.appendingPathComponent("specs/005-cli-control/contracts/coverage.md"), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let tail = lines.drop { !$0.hasPrefix("**Не входит**") }
        let tableCells = lines.filter { $0.hasPrefix("| ") }.compactMap { $0.split(separator: "|", omittingEmptySubsequences: false).dropFirst().first.map(String.init) }
        let spans = try NSRegularExpression(pattern: "`([^`]+)`")
        var result = Mentions()
        for line in tableCells + Array(tail) {
            for match in spans.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                var span = String(line[Range(match.range(at: 1), in: line)!])
                span = span.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
                var owner: String?
                for (index, piece) in span.split(separator: "/").map(String.init).enumerated() {
                    var name = piece
                    if index == 0, let dot = piece.firstIndex(of: ".") {
                        owner = String(piece[..<dot])
                        name = String(piece[piece.index(after: dot)...])
                    }
                    if let owner { result.qualified.insert("\(owner).\(name)") } else { result.unqualified.insert(name) }
                }
            }
        }
        return result
    }

    @Test func everyPublicOperationHasCommandOrReason() throws {
        let methods = try Dictionary(uniqueKeysWithValues: Self.operationClasses.map { ($0, try Self.publicMethods(of: $0)) })
        let mentions = try Self.mentions()
        var missing: [String] = []
        for (operationClass, names) in methods {
            for name in names.sorted() {
                let shared = methods.contains { $0.key != operationClass && $0.value.contains(name) }
                if !mentions.covers(name, in: operationClass, uniqueName: !shared) {
                    missing.append("\(operationClass).\(name)" + (shared ? " (имя есть в нескольких классах: писать с классом)" : ""))
                }
            }
        }
        #expect(missing.isEmpty, """
            Операции без строки в specs/005-cli-control/contracts/coverage.md: \(missing.sorted().joined(separator: ", ")). \
            Допишите команду и строку таблицы или внесите метод в «Методы без команды» с причиной.
            """)
    }

    @Test func tableStaysAtCurrentCode() throws {
        // Страховка парсера: известные методы находятся, иначе тест выше проходил бы на пустом.
        #expect(try Self.publicMethods(of: "PageTreeOperations").isSuperset(of: ["createSubpage", "moveToTrash", "restoreVersion"]))
        #expect(try Self.publicMethods(of: "DatabaseOperations").isSuperset(of: ["createDatabase", "setCell", "setFilter"]))
        #expect(try Self.publicMethods(of: "WindowTabs").isSuperset(of: ["open", "reopenClosedTab", "goBack"]))
    }

    /// У каждой команды каталога есть обработчик: исключений нет (шаблоны строк `db template …` — 004, US6).
    @Test func everyCatalogCommandHasHandler() {
        let withoutHandler = CommandCatalog.all.filter { HandlerRegistry.standard.handler(for: $0.name) == nil }
        let names = withoutHandler.map(\.invocation).joined(separator: ", ")
        #expect(withoutHandler.isEmpty, "Команды без обработчика: \(names)")
    }
}
