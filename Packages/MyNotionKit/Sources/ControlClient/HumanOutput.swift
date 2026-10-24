import ControlProtocol

/// Вывод для человека (`--human`): успех — текст приложения в stdout, ошибка — «✗ …» и «→ подсказка» в stderr.
enum HumanOutput {
    static func success(_ response: ControlResponse) -> String {
        if let text = response.text, !text.isEmpty { return text + "\n" }
        guard let data = response.data, data != true, data != [:] else { return "✓ Готово\n" }
        return data.encodedText() + "\n"
    }

    static func warnings(_ response: ControlResponse) -> String {
        response.warnings.map { warning in
            "! " + warning.message + (warning.line.map { " (строка \($0))" } ?? "") + "\n"
        }.joined()
    }

    static func failure(_ error: ControlError) -> String {
        "✗ \(error.message)\n" + (error.hint.map { "→ \($0)\n" } ?? "")
    }
}
