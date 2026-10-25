import Foundation
import Testing
@testable import ControlProtocol

@Suite struct ProtocolCodingTests {
    @Test func requestEncodesAsContract() throws {
        let request = ControlRequest(id: "c0a8", command: "page.create", args: ["parent": "Проекты", "title": "Встреча 24.10"],
                                     agent: "Codex", timeoutMs: 30_000, cwd: "/Users/ykurilov/work")
        let line = try LineFraming.frame(request)
        let text = String(decoding: line, as: UTF8.self)
        #expect(text == #"{"agent":"Codex","args":{"parent":"Проекты","title":"Встреча 24.10"},"command":"page.create","cwd":"/Users/ykurilov/work","id":"c0a8","protocol":1,"timeoutMs":30000}"# + "\n")
        #expect(try LineFraming.decode(ControlRequest.self, from: line.dropLast()) == request)
    }

    @Test func requestDefaultsWhenOmitted() throws {
        let request = try LineFraming.decode(ControlRequest.self, from: Data(#"{"protocol":1,"command":"app.status"}"#.utf8))
        #expect(request.agent == "агент")
        #expect(request.timeoutMs == 30_000)
        #expect(request.args.isEmpty)
        #expect(!request.human)
    }

    @Test func successAndFailure() throws {
        let success = ControlResponse.success("c0a8", ["page": ["id": "3f2a"]],
                                              warnings: [ControlWarning(.markdownUnsupported, "HTML", line: 12)])
        #expect(String(decoding: try ControlCoding.encoder.encode(success), as: UTF8.self)
            == #"{"data":{"page":{"id":"3f2a"}},"id":"c0a8","ok":true,"warnings":[{"code":"markdown_unsupported","line":12,"message":"HTML"}]}"#)

        let failure = ControlResponse.failure("c0a8", ControlError(.pageNotFound, "Страница «Проекты/Встрча» не найдена",
                                                                   hint: "mynotion page tree --depth 2", details: ["path": "Проекты/Встрча"]))
        let text = String(decoding: try ControlCoding.encoder.encode(failure), as: UTF8.self)
        #expect(text == #"{"error":{"code":"page_not_found","details":{"path":"Проекты/Встрча"},"hint":"mynotion page tree --depth 2","message":"Страница «Проекты/Встрча» не найдена"},"id":"c0a8","ok":false}"#)
        #expect(try ControlCoding.decoder.decode(ControlResponse.self, from: Data(text.utf8)) == failure)
    }

    @Test func progressLine() throws {
        let line = ControlResponseLine.progress(id: "c1", ControlProgress(done: 120, total: 900, stage: "Страницы"))
        let text = String(decoding: try ControlCoding.encoder.encode(line), as: UTF8.self)
        #expect(text == #"{"id":"c1","progress":{"done":120,"stage":"Страницы","total":900}}"#)
        #expect(try ControlCoding.decoder.decode(ControlResponseLine.self, from: Data(text.utf8)) == line)
        #expect(!line.isFinal)
        let result = ControlResponseLine.result(.success("c1", ["n": 1]))
        let decoded = try ControlCoding.decoder.decode(ControlResponseLine.self, from: try ControlCoding.encoder.encode(result))
        #expect(decoded == result)
        #expect(decoded.isFinal)
    }

    @Test func frameIsOneLineWithEscapedNewlines() throws {
        let request = ControlRequest(command: "page.write", args: ["page": "А", "markdown": "строка 1\nстрока 2\n"])
        let frame = try LineFraming.frame(request)
        #expect(frame.filter { $0 == LineFraming.newline }.count == 1)
        #expect(frame.last == LineFraming.newline)
        #expect(try LineFraming.decode(ControlRequest.self, from: frame.dropLast()).args["markdown"] == "строка 1\nстрока 2\n")
    }

    @Test func lineBufferSplitsAndLimits() throws {
        var buffer = LineBuffer(limit: 10)
        #expect(try buffer.append(Data("abc".utf8)).isEmpty)
        #expect(try buffer.append(Data("de\nfg\nh".utf8)) == [Data("abcde".utf8), Data("fg".utf8)])
        #expect(buffer.remainder == Data("h".utf8))
        #expect(throws: LineBuffer.Failure.frameTooLarge) { try buffer.append(Data("0123456789x".utf8)) }
    }

    @Test func defaultFrameLimitIs64MB() throws {
        var buffer = LineBuffer()
        #expect(buffer.limit == 64 * 1024 * 1024)
        let chunk = Data(repeating: UInt8(ascii: "a"), count: 16 * 1024 * 1024)
        for _ in 0..<4 { _ = try buffer.append(chunk) }
        #expect(throws: LineBuffer.Failure.frameTooLarge) { try buffer.append(Data("a".utf8)) }
    }

    /// Строку по байту — как медленный клиент: каждый кусок не перебирает заново всё накопленное.
    @Test func lineBufferDoesNotRescanPending() throws {
        var buffer = LineBuffer()
        let byte = Data("a".utf8)
        let started = ContinuousClock.now
        for _ in 0..<65_536 { _ = try buffer.append(byte) }
        let lines = try buffer.append(Data("\n".utf8))
        #expect(lines.first?.count == 65_536)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func everyErrorCodeHasGroupAndExitCode() {
        let table: [Int32: [String]] = [
            2: ["unknown_command", "invalid_argument", "missing_argument", "invalid_value", "invalid_markdown", "invalid_formula",
                "not_batchable", "force_required"],
            3: ["page_not_found", "block_not_found", "database_not_found", "property_not_found", "option_not_found", "view_not_found",
                "row_not_found", "version_not_found", "attachment_not_found", "file_not_found", "window_not_found", "tab_not_found",
                "template_not_found"],
            4: ["ambiguous_page", "page_in_trash", "cannot_move", "wrong_page", "read_only_property", "window_busy", "batch_failed",
                "not_implemented", "sync_disabled"],
            5: ["app_not_running", "app_not_ready", "app_disconnected", "timeout", "version_mismatch"],
            1: ["internal", "write_failed"],
        ]
        #expect(table.values.map(\.count).reduce(0, +) == ControlErrorCode.allCases.count)
        for (exit, codes) in table {
            for raw in codes {
                #expect(ControlErrorCode(rawValue: raw)?.exitCode == exit, "\(raw)")
            }
        }
        #expect(Set(ControlWarningCode.allCases.map(\.rawValue)) == ["markdown_unsupported", "option_created", "value_converted", "truncated",
                                                                         "not_moved"])
    }

    @Test func jsonValuesRoundTrip() throws {
        let value: ControlJSON = ["n": 3, "x": 1.5, "s": "т", "b": false, "z": nil, "a": [1, "2"]]
        #expect(value.encodedText() == #"{"a":[1,"2"],"b":false,"n":3,"s":"т","x":1.5,"z":null}"#)
        #expect(try ControlJSON(parsing: value.encodedText()) == value)
        #expect(value.value(atPath: "a.1") == "2")
    }
}
