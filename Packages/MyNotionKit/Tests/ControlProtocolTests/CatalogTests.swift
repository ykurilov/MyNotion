import Foundation
import Testing
@testable import ControlProtocol

/// Каталог против contracts/commands.md: файл контракта — фикстура, каталог и контракт не расходятся.
@Suite struct CatalogTests {
    struct ContractCommand: Hashable {
        var name: String
        var access: CommandAccess
        var batchable: Bool
        var stage: Int
    }

    static let contract: [ContractCommand] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("specs/005-cli-control/contracts/commands.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var commands: [ContractCommand] = []
        var stage = 0
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("## "), let found = Self.stage(in: line) { stage = found }
            guard line.hasPrefix("| `") else { continue }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let names = Self.names(in: cells[1])
            let types = Self.types(in: cells[cells.count - 2])
            let rowStage = Self.stage(in: cells[cells.count - 2]) ?? stage
            for (index, words) in names.enumerated() {
                let type = index == 0 ? types.first : types.last
                commands.append(ContractCommand(name: words.joined(separator: "."), access: type!.access, batchable: type!.batchable,
                                                stage: rowStage))
            }
        }
        return commands
    }()

    /// «`db option add` / `rename`» → db.option.add, db.option.rename.
    static func names(in cell: String) -> [[String]] {
        let parts = cell.components(separatedBy: "`").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        guard let first = parts.first?.split(separator: " ").map(String.init) else { return [] }
        return [first] + parts.dropFirst().map { part in
            let words = part.split(separator: " ").map(String.init)
            return words.first == first.first ? words : Array(first.dropLast()) + words
        }
    }

    /// «R», «W B», «R / W B», «R: …», «R (…)».
    static func types(in cell: String) -> [(access: CommandAccess, batchable: Bool)] {
        let head = cell.prefix { $0 != ":" && $0 != "(" }
        return head.components(separatedBy: " / ").map { part in
            let words = part.split(separator: " ")
            return (words.first == "W" ? .write : .read, words.contains("B"))
        }
    }

    static func stage(in text: String) -> Int? {
        guard let range = text.range(of: #"этап (\d+)"#, options: .regularExpression) else { return nil }
        return Int(text[range].dropFirst(5))
    }

    @Test func contractIsRead() {
        #expect(Self.contract.count > 100)
    }

    @Test func everyContractCommandIsInCatalog() {
        for command in Self.contract {
            guard let spec = CommandCatalog.spec(for: command.name) else {
                Issue.record("Нет в каталоге: \(command.name)")
                continue
            }
            #expect(spec.access == command.access, "\(command.name): тип")
            #expect(spec.batchable == command.batchable, "\(command.name): batch")
            #expect(spec.stage == command.stage, "\(command.name): этап")
        }
    }

    @Test func catalogHasNothingBeyondContract() {
        let contractNames = Set(Self.contract.map(\.name))
        let extra = CommandCatalog.all.map(\.name).filter { !contractNames.contains($0) }
        #expect(extra.isEmpty, "Лишние в каталоге: \(extra)")
    }

    @Test func namesAreUnique() {
        let names = CommandCatalog.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func everyCommandHasSummaryAndExample() {
        for spec in CommandCatalog.all {
            #expect(!spec.summary.isEmpty, "\(spec.name): описание")
            #expect(spec.example.contains("mynotion " + spec.invocation), "\(spec.name): пример «\(spec.example)»")
            for argument in spec.arguments {
                #expect(!argument.summary.isEmpty, "\(spec.name).\(argument.name): описание аргумента")
            }
        }
    }

    @Test func groupsHaveSummaries() {
        for group in CommandCatalog.groups {
            #expect(CommandCatalog.groupSummaries[group] != nil, "\(group)")
        }
    }

    @Test func exclusiveAndOneOfNameRealArguments() {
        for spec in CommandCatalog.all {
            for name in (spec.exclusive + spec.requiresOneOf).flatMap({ $0 }) {
                #expect(spec.argument(named: name) != nil, "\(spec.name): \(name)")
            }
        }
    }

    @Test func positionalsAreInParsableOrder() {
        // Повторяемый позиционный забирает остаток — после него позиционных нет.
        for spec in CommandCatalog.all {
            let positionals = spec.positionals
            if let index = positionals.firstIndex(where: \.repeated) {
                #expect(index == positionals.count - 1, "\(spec.name)")
            }
        }
    }

    @Test func commandsJSONIsStable() throws {
        let first = CommandCatalog.json.encodedText()
        let second = CommandCatalog.json.encodedText()
        #expect(first == second)
        let parsed = try ControlJSON(parsing: first)
        #expect(parsed["protocol"] == 1)
        #expect(parsed["commands"]?.array?.compactMap { $0["name"]?.string } == CommandCatalog.all.map(\.name))
        #expect(parsed["globalFlags"]?.array?.count == GlobalFlag.allCases.count)
        let create = parsed["commands"]?.array?.first { $0["name"] == "page.create" }
        #expect(create?["access"] == "write")
        #expect(create?["batchable"] == true)
        #expect(create?["arguments"]?.array?.contains { $0["flag"] == "--title" && $0["required"] == true } == true)
    }

    @Test func suggestionFindsTypo() {
        #expect(CommandCatalog.suggestion(for: ["page", "craete"])?.name == "page.create")
        #expect(CommandCatalog.suggestion(for: ["zzzzzz", "qqqqqq"]) == nil)
    }
}
