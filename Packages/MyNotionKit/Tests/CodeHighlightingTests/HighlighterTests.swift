import Foundation
import Testing
@testable import CodeHighlighting

/// Подсветка кода (research R5): токены 24 языков, многострочные комментарии и строки, перекраска до совпадения состояния.
@Suite("Подсветка кода")
struct HighlighterTests {
    /// Образец языка: строка кода и что в ней должно найтись.
    struct Sample: CustomTestStringConvertible, Sendable {
        var language: LanguageDefinition
        var code: String
        var expected: [(String, CodeTokenKind)]
        var testDescription: String { language.title }
    }

    static let samples: [Sample] = [
        Sample(language: .swift, code: "let name: String = \"Мир\" // привет\nfunc go() { return 42 }",
               expected: [("let", .keyword), ("String", .type), ("\"Мир\"", .string), ("// привет", .comment), ("go", .function),
                          ("42", .number), ("return", .keyword)]),
        Sample(language: .python, code: "def area(r):\n    return 3.14 * r ** 2  # площадь\nprint('ok', True)",
               expected: [("def", .keyword), ("area", .function), ("3.14", .number), ("# площадь", .comment), ("'ok'", .string),
                          ("True", .literal)]),
        Sample(language: .javascript, code: "const total = items.length + 1; // число\nconsole.log(`итог ${total}`)",
               expected: [("const", .keyword), ("1", .number), ("// число", .comment), ("`итог ${total}`", .string), ("log", .function)]),
        Sample(language: .typescript, code: "interface User { id: number }\nlet u: User = { id: 7 } /* да */",
               expected: [("interface", .keyword), ("number", .type), ("User", .type), ("7", .number), ("/* да */", .comment)]),
        Sample(language: .jsx, code: "return <Button kind=\"primary\">{label}</Button> // кнопка",
               expected: [("return", .keyword), ("Button", .tag), ("kind", .attribute), ("\"primary\"", .string), ("// кнопка", .comment)]),
        Sample(language: .html, code: "<a href=\"/x\" class='y'>Ссылка</a> <!-- c -->",
               expected: [("a", .tag), ("href", .attribute), ("\"/x\"", .string), ("'y'", .string), ("<!-- c -->", .comment)]),
        Sample(language: .css, code: ".card:hover { color: #333; margin: 12px 0 } /* тень */",
               expected: [("color", .property), ("margin", .property), ("12px", .number), ("/* тень */", .comment)]),
        Sample(language: .scss, code: "$gap: 8px;\n.box { padding: $gap * 2; } // отступ",
               expected: [("$gap", .variable), ("padding", .property), ("8px", .number), ("2", .number), ("// отступ", .comment)]),
        Sample(language: .json, code: "{\"name\": \"MyNotion\", \"count\": 3, \"ok\": true, \"none\": null}",
               expected: [("\"name\"", .property), ("\"MyNotion\"", .string), ("3", .number), ("true", .literal), ("null", .literal)]),
        Sample(language: .sql, code: "SELECT id, title FROM pages WHERE id = 10 -- страницы\nselect 'текст'",
               expected: [("SELECT", .keyword), ("FROM", .keyword), ("WHERE", .keyword), ("10", .number), ("-- страницы", .comment),
                          ("select", .keyword), ("'текст'", .string)]),
        Sample(language: .bash, code: "for f in *.md; do echo \"$f\"; done # файлы\nexport PATH=$HOME/bin",
               expected: [("for", .keyword), ("do", .keyword), ("\"$f\"", .string), ("# файлы", .comment), ("$HOME", .variable)]),
        Sample(language: .markdown, code: "# Заголовок\n- пункт с `кодом`\n```\nlet x = 1\n```",
               expected: [("# Заголовок", .tag), ("-", .punctuation), ("`кодом`", .string), ("let x = 1", .string)]),
        Sample(language: .yaml, code: "name: MyNotion # имя\nversion: 2\nitems:\n  - id: true",
               expected: [("name", .property), ("# имя", .comment), ("version", .property), ("2", .number), ("id", .property),
                          ("true", .literal)]),
        Sample(language: .toml, code: "[server]\nport = 8080 # порт\nname = \"mynotion\"",
               expected: [("[server]", .tag), ("port", .property), ("8080", .number), ("# порт", .comment), ("\"mynotion\"", .string)]),
        Sample(language: .xml, code: "<?xml version=\"1.0\"?>\n<plist><key>Name</key></plist> <!-- x -->",
               expected: [("xml", .tag), ("version", .attribute), ("\"1.0\"", .string), ("plist", .tag), ("key", .tag), ("<!-- x -->", .comment)]),
        Sample(language: .c, code: "#include <stdio.h>\nint main(void) { return 0; } // вход",
               expected: [("#include", .annotation), ("int", .type), ("main", .function), ("return", .keyword), ("0", .number),
                          ("// вход", .comment)]),
        Sample(language: .cpp, code: "std::vector<int> v; auto x = nullptr; // c++\nclass A {};",
               expected: [("int", .type), ("auto", .keyword), ("nullptr", .literal), ("// c++", .comment), ("class", .keyword)]),
        Sample(language: .csharp, code: "public class Note { string Title = \"x\"; } // c#",
               expected: [("public", .keyword), ("class", .keyword), ("Note", .type), ("string", .type), ("\"x\"", .string),
                          ("// c#", .comment)]),
        Sample(language: .java, code: "@Override public int size() { return 0x1F; } /* j */",
               expected: [("@Override", .annotation), ("public", .keyword), ("int", .type), ("size", .function), ("0x1F", .number),
                          ("/* j */", .comment)]),
        Sample(language: .kotlin, code: "val name: String = \"$user\" // k\nfun main() = println(1)",
               expected: [("val", .keyword), ("String", .type), ("\"$user\"", .string), ("// k", .comment), ("fun", .keyword),
                          ("println", .function)]),
        Sample(language: .go, code: "func main() { x := 42; fmt.Println(\"go\") } // g",
               expected: [("func", .keyword), ("main", .function), ("42", .number), ("Println", .function), ("\"go\"", .string),
                          ("// g", .comment)]),
        Sample(language: .rust, code: "fn main() { let mut n: u32 = 5; println!(\"r\"); } // р",
               expected: [("fn", .keyword), ("let", .keyword), ("mut", .keyword), ("u32", .type), ("5", .number), ("\"r\"", .string),
                          ("// р", .comment)]),
        Sample(language: .ruby, code: "def hello(name)\n  puts \"Hi\" if true # r\nend",
               expected: [("def", .keyword), ("hello", .function), ("\"Hi\"", .string), ("true", .literal), ("# r", .comment),
                          ("end", .keyword)]),
        Sample(language: .php, code: "<?php function sum($a) { return $a + 1; } // p",
               expected: [("function", .keyword), ("sum", .function), ("$a", .variable), ("return", .keyword), ("1", .number),
                          ("// p", .comment)]),
    ]

    static func tokens(_ language: LanguageDefinition, _ code: String) -> [(String, CodeTokenKind)] {
        let highlighter = IncrementalHighlighter(language: language, text: code)
        let units = Array(code.utf16)
        return highlighter.tokens(inLines: 0..<highlighter.lines.count).map {
            (String(decoding: units[$0.range], as: UTF16.self), $0.kind)
        }
    }

    @Test("24 языка в окне выбора, плюс «Простой текст»")
    func languageList() {
        #expect(LanguageDefinition.all.count == 25)
        #expect(Set(Self.samples.map(\.language.id)).count == 24)
        #expect(LanguageDefinition.all.first == .plain)
    }

    @Test("Ключевые слова, строки, числа, комментарии", arguments: samples)
    func sampleTokens(_ sample: Sample) {
        let found = Self.tokens(sample.language, sample.code)
        for (text, kind) in sample.expected {
            #expect(found.contains { $0.0 == text && $0.1 == kind }, "\(sample.language.title): нет «\(text)» как \(kind); есть \(found)")
        }
    }

    @Test("Простой текст не подсвечивается")
    func plainHasNoTokens() {
        #expect(Self.tokens(.plain, "let x = 1 // нет").isEmpty)
    }

    @Test("Язык по имени из ограды Markdown")
    func languageByFenceName() {
        #expect(LanguageDefinition.named("js") == .javascript)
        #expect(LanguageDefinition.named("TSX") == .jsx)
        #expect(LanguageDefinition.named("sh") == .bash)
        #expect(LanguageDefinition.named("c++") == .cpp)
        #expect(LanguageDefinition.named("Swift") == .swift)
        #expect(LanguageDefinition.named("brainfuck") == nil)
        #expect(LanguageDefinition.forBlock(nil) == .plain)
        #expect(LanguageDefinition.forBlock("cobol") == .plain)
    }

    @Test("Многострочный комментарий и строка: состояние переходит на следующие строки")
    func multilineState() {
        let comment = IncrementalHighlighter(language: .swift, text: "let a = 1 /* начало\nвнутри\nконец */ let b = 2")
        #expect(comment.lines.map(\.end) == [.blockComment(0), .blockComment(0), .normal])
        #expect(comment.lines[1].tokens == [CodeToken(0..<6, .comment)])
        #expect(comment.lines[2].tokens.contains(CodeToken(17..<18, .number)))

        let string = IncrementalHighlighter(language: .python, text: "s = \"\"\"первая\nвторая\n\"\"\" + 'x'")
        #expect(string.lines.map(\.end) == [.string(0), .string(0), .normal])
        #expect(string.lines[1].tokens == [CodeToken(0..<6, .string)])
    }

    @Test("Открыли комментарий правкой — перекрашено всё ниже; закрыли — снова код")
    func editOpensAndClosesComment() {
        var text = "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4"
        var highlighter = IncrementalHighlighter(language: .swift, text: text)
        // «/*» в начало второй строки.
        let insertAt = 10
        text = (text as NSString).replacingCharacters(in: NSRange(location: insertAt, length: 0), with: "/*")
        let opened = highlighter.apply(text: text, editedRange: NSRange(location: insertAt, length: 2), changeInLength: 2)
        #expect(opened == 1..<4)
        #expect(highlighter.lines.dropFirst().allSatisfy { $0.tokens.map(\.kind) == [.comment] })
        // «*/» в конец третьей строки.
        let closeAt = (text as NSString).range(of: "let c = 3").upperBound
        text = (text as NSString).replacingCharacters(in: NSRange(location: closeAt, length: 0), with: "*/")
        let closed = highlighter.apply(text: text, editedRange: NSRange(location: closeAt, length: 2), changeInLength: 2)
        #expect(closed == 2..<4)
        #expect(highlighter.lines[3].tokens.first == CodeToken(0..<3, .keyword))
        #expect(highlighter == IncrementalHighlighter(language: .swift, text: text))
    }

    @Test("Набор в строке перекрашивает одну строку: состояние конца совпало")
    func typingStopsAtMatchingState() {
        var text = (0..<20).map { "let value\($0) = \($0) // строка" }.joined(separator: "\n")
        var highlighter = IncrementalHighlighter(language: .swift, text: text)
        let at = (text as NSString).range(of: "value10").upperBound
        text = (text as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: "x")
        #expect(highlighter.apply(text: text, editedRange: NSRange(location: at, length: 1), changeInLength: 1) == 10..<11)
        // Enter посреди строки: две новые строки на месте одной, дальше — сдвиг без разбора.
        text = (text as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: "\n")
        #expect(highlighter.apply(text: text, editedRange: NSRange(location: at, length: 1), changeInLength: 1) == 10..<12)
        #expect(highlighter.lines.count == 21)
        // Удаление перевода строки склеивает строки обратно.
        text = (text as NSString).replacingCharacters(in: NSRange(location: at, length: 1), with: "")
        #expect(highlighter.apply(text: text, editedRange: NSRange(location: at, length: 0), changeInLength: -1) == 10..<11)
        #expect(highlighter == IncrementalHighlighter(language: .swift, text: text))
    }

    @Test("Полный разбор 500 строк — быстрее 50 мс")
    func fullParseTiming() {
        let text = (0..<500).map { index in
            switch index % 5 {
            case 0: "func step\(index)(value: Int) -> Int {"
            case 1: "    let doubled = value * 2 // строка \(index)"
            case 2: "    guard doubled > 0 else { return 0 }"
            case 3: "    return doubled + \"текст\".count"
            default: "}"
            }
        }.joined(separator: "\n")
        let clock = ContinuousClock()
        var highlighter: IncrementalHighlighter?
        let full = clock.measure { highlighter = IncrementalHighlighter(language: .swift, text: text) }
        var editable = highlighter!
        let at = (text as NSString).range(of: "строка 251").upperBound
        let edited = (text as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: "x")
        let line = clock.measure { editable.apply(text: edited, editedRange: NSRange(location: at, length: 1), changeInLength: 1) }
        print("Подсветка: полный разбор 500 строк — \(full), правка строки — \(line)")
        #expect(highlighter?.lines.count == 500)
        #expect(full < .milliseconds(50))
        #expect(line < .milliseconds(10))
    }
}

extension IncrementalHighlighter: Equatable {
    public static func == (lhs: IncrementalHighlighter, rhs: IncrementalHighlighter) -> Bool {
        lhs.lines == rhs.lines && lhs.lineStarts == rhs.lineStarts && lhs.language == rhs.language
    }
}
