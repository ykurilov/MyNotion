import Foundation

/// Справка на трёх уровнях (FR-407): вся команда, группа, одна команда. Строится из каталога, без приложения.
public enum CommandHelp {
    public static func top() -> String {
        var lines = ["mynotion — управление MyNotion из командной строки", "",
                     "Использование: mynotion <группа> <команда> [аргументы] [флаги]", "", "Группы:"]
        let width = CommandCatalog.groups.map(\.count).max() ?? 0
        for group in CommandCatalog.groups {
            let summary = CommandCatalog.groupSummaries[group] ?? ""
            lines.append("  " + group.padding(toLength: width + 2, withPad: " ", startingAt: 0) + summary)
        }
        lines += ["", "Общие флаги:"] + globalFlagLines()
        lines += ["", "Ответ — JSON в stdout, код выхода: 0 — успех, 2 — ошибка в команде, 3 — не найдено,",
                  "4 — нельзя сейчас, 5 — приложение недоступно, 1 — сбой.",
                  "Справка группы: mynotion <группа> --help; команды: mynotion <группа> <команда> --help"]
        return lines.joined(separator: "\n")
    }

    /// Группа или подгруппа (`db`, `db prop`): её команды.
    public static func group(_ words: [String]) -> String {
        let commands = CommandCatalog.all.filter { $0.words.starts(with: words) && $0.words.count > words.count }
        guard !commands.isEmpty else { return top() }
        let title = words.joined(separator: " ")
        var lines = ["mynotion \(title)" + (CommandCatalog.groupSummaries[title].map { " — \($0)" } ?? ""), "", "Команды:"]
        let width = commands.map(\.invocation.count).max() ?? 0
        for spec in commands {
            lines.append("  " + spec.invocation.padding(toLength: width + 2, withPad: " ", startingAt: 0) + spec.summary)
        }
        lines += ["", "Подробно: mynotion \(title) <команда> --help"]
        return lines.joined(separator: "\n")
    }

    public static func command(_ spec: CommandSpec) -> String {
        var lines = ["mynotion \(spec.invocation) — \(spec.summary)", "", "Использование: mynotion \(spec.usage)"]
        if !spec.arguments.isEmpty {
            lines += ["", "Аргументы:"]
            let labels = spec.arguments.map { argument in
                argument.flag.map { "--\($0)" + (argument.type == .bool ? "" : " " + argument.type.placeholder) }
                    ?? argument.type.placeholder + (argument.repeated ? "…" : "")
            }
            let width = labels.map(\.count).max() ?? 0
            for (label, argument) in zip(labels, spec.arguments) {
                var text = argument.summary
                if argument.required { text += " (обязательно)" }
                if let value = argument.defaultValue { text += " (по умолчанию \(value.string ?? value.encodedText()))" }
                lines.append("  " + label.padding(toLength: width + 2, withPad: " ", startingAt: 0) + text)
            }
        }
        for group in spec.exclusive {
            lines.append("Не вместе: " + group.map { spec.label(of: $0) }.joined(separator: ", "))
        }
        for group in spec.requiresOneOf {
            lines.append("Нужен один из: " + group.map { spec.label(of: $0) }.joined(separator: ", "))
        }
        var traits = [spec.access == .read ? "только чтение" : "изменяет данные"]
        if spec.batchable { traits.append("можно в batch") }
        if spec.isLong { traits.append("долгая: срок 10 минут, ход строками progress") }
        lines += ["", traits.joined(separator: "; ").prefix(1).uppercased() + traits.joined(separator: "; ").dropFirst(),
                  "", "Пример:", "  " + spec.example]
        return lines.joined(separator: "\n")
    }

    static func globalFlagLines() -> [String] {
        let labels = GlobalFlag.allCases.map { "--" + $0.rawValue + ($0.takesValue ? " <значение>" : "") }
        let width = labels.map(\.count).max() ?? 0
        return zip(labels, GlobalFlag.allCases).map { label, flag in
            "  " + label.padding(toLength: width + 2, withPad: " ", startingAt: 0) + flag.summary
        }
    }
}
