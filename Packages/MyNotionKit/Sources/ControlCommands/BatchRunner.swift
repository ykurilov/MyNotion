import ControlProtocol
import Foundation

/// Пакет (research R6): все шаги проверяются до выполнения, идут под одним замком записи, каждый — свой шаг отмены
/// общей сессии. Ошибка шага откатывает весь пакет. `"$N.путь"` — значение из ответа шага N (с 1).
@MainActor
struct BatchRunner {
    let session: CommandSession

    struct Step {
        let number: Int
        let spec: CommandSpec
        let args: [String: ControlJSON]
        let handler: CommandHandler
    }

    func run() async throws -> CommandResult {
        let steps = try prepare()
        var results: [ControlJSON] = []
        for step in steps {
            do {
                let args = try CommandCatalog.normalized(try resolve(step.args, results: results), for: step.spec)
                let stepSession = session.step(step.spec, args: args)
                let result = try await session.context.grouped { try await step.handler(stepSession) }
                results.append(result.data)
            } catch {
                session.context.rollBack()
                let inner = ControlError.wrapping(error)
                throw ControlError(.batchFailed, "Шаг \(step.number) («\(step.spec.invocation)»): \(inner.message). Пакет откачен",
                                   hint: inner.hint, details: ["step": .number(Double(step.number)), "command": .string(step.spec.name),
                                                               "error": inner.json])
            }
        }
        return CommandResult(["steps": .array(results)], text: "✓ Пакет: \(steps.count) \(Self.stepsWord(steps.count))")
    }

    /// Проверка всего пакета до первого шага: команда есть, её можно в пакет, аргументы верны (кроме подстановок).
    func prepare() throws(ControlError) -> [Step] {
        guard let items = session.args["steps"]?.array, !items.isEmpty else {
            throw ControlError(.invalidValue, "Шаги пакета — непустой список [{\"command\":…,\"args\":{…}}]", hint: "Пример: \(session.spec.example)",
                               details: ["argument": "steps"])
        }
        var steps: [Step] = []
        for (index, item) in items.enumerated() {
            let number = index + 1
            func failure(_ error: ControlError) -> ControlError {
                var error = error
                var details = error.details?.object ?? [:]
                details["step"] = .number(Double(number))
                error.details = .object(details)
                error.message = "Шаг \(number): \(error.message)"
                return error
            }
            guard let command = item["command"]?.string else {
                throw failure(ControlError(.invalidValue, "Нет имени команды в поле \"command\"", hint: "Пример: \(session.spec.example)"))
            }
            let args = item["args"]?.object ?? [:]
            let spec: CommandSpec
            let handler: CommandHandler
            do throws(ControlError) {
                let words = command.split(whereSeparator: { $0 == "." || $0 == " " }).map(String.init)
                guard let found = CommandCatalog.spec(words: words) else {
                    throw ControlError(.unknownCommand, "Нет команды «\(words.joined(separator: " "))»", hint: "Список команд: mynotion --help")
                }
                guard found.batchable else {
                    throw ControlError(.notBatchable, "Команду «\(found.invocation)» нельзя в пакет: у неё нет точной отмены",
                                       hint: "Выполните её отдельно", details: ["command": .string(found.name)])
                }
                guard let foundHandler = session.registry.handler(for: found.name) else {
                    throw ControlError.notImplemented(stage: found.stage, command: found.invocation)
                }
                spec = found
                handler = foundHandler
                do throws(ControlError) {
                    _ = try CommandCatalog.normalized(args, for: spec)
                } catch let invalid where Self.isReference(args[invalid.details?["argument"]?.string ?? ""]) {
                    // Значение подставится из прошлого шага: проверка — перед самим шагом.
                }
            } catch {
                throw failure(error)
            }
            steps.append(Step(number: number, spec: spec, args: args, handler: handler))
        }
        return steps
    }

    static func isReference(_ value: ControlJSON?) -> Bool {
        guard let text = value?.string, text.hasPrefix("$") else { return false }
        return reference(text) != nil
    }

    /// `$2.page.id` → (2, "page.id").
    static func reference(_ text: String) -> (step: Int, path: String)? {
        guard text.hasPrefix("$"), let dot = text.firstIndex(of: "."), let step = Int(text[text.index(after: text.startIndex)..<dot]) else {
            return nil
        }
        return (step, String(text[text.index(after: dot)...]))
    }

    func resolve(_ args: [String: ControlJSON], results: [ControlJSON]) throws(ControlError) -> [String: ControlJSON] {
        var resolved: [String: ControlJSON] = [:]
        for (key, value) in args {
            resolved[key] = try resolve(value, results: results)
        }
        return resolved
    }

    func resolve(_ value: ControlJSON, results: [ControlJSON]) throws(ControlError) -> ControlJSON {
        switch value {
        case .string(let text):
            guard text.hasPrefix("$"), let (step, path) = Self.reference(text) else { return value }
            guard step >= 1, step <= results.count, let found = results[step - 1].value(atPath: path) else {
                throw ControlError(.invalidArgument, "Подстановка «\(text)»: в ответе шага \(step) нет «\(path)»",
                                   hint: "Номер — один из прошлых шагов (с 1), путь — через точку: $1.page.id",
                                   details: ["reference": .string(text)])
            }
            return found
        case .array(let items):
            var resolved: [ControlJSON] = []
            for item in items { resolved.append(try resolve(item, results: results)) }
            return .array(resolved)
        case .object(let object):
            return .object(try resolve(object, results: results))
        default:
            return value
        }
    }

    static func stepsWord(_ count: Int) -> String {
        let tens = count % 100, ones = count % 10
        if (11...14).contains(tens) { return "шагов" }
        switch ones {
        case 1: return "шаг"
        case 2...4: return "шага"
        default: return "шагов"
        }
    }
}

extension ControlError {
    /// Ошибка как JSON — внутри `details` пакета.
    var json: ControlJSON {
        var object: [String: ControlJSON] = ["code": .string(code.rawValue), "message": .string(message)]
        if let hint { object["hint"] = .string(hint) }
        if let details { object["details"] = details }
        return .object(object)
    }
}
