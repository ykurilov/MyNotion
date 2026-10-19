import Foundation


/// Подсветка кода (research R5): свой построчный разборщик, языки — таблицами данных, без зависимостей.
/// Как Prism у Notion: словари токенов, без полного разбора языка.

/// Вид токена — по нему редактор берёт цвет темы.
public enum CodeTokenKind: String, Sendable, Hashable, CaseIterable {
    case keyword
    case type
    case string
    case number
    case comment
    case function
    /// `true`, `false`, `nil`, `null`.
    case literal
    /// Ключ JSON, YAML, TOML, свойство CSS.
    case property
    /// Тег HTML, XML, JSX; заголовок Markdown.
    case tag
    case attribute
    /// `$name` в Bash, PHP, SCSS.
    case variable
    /// `@Decorator`, `#include`, `@media`.
    case annotation
    case punctuation
}

/// Строка в языке: открывающие и закрывающие знаки, знак экранирования, может ли тянуться через строки кода.
public struct StringRule: Sendable, Hashable {
    public var open: String
    public var close: String
    public var escape: Character?
    public var multiline: Bool

    public init(_ open: String, _ close: String? = nil, escape: Character? = "\\", multiline: Bool = false) {
        self.open = open
        self.close = close ?? open
        self.escape = escape
        self.multiline = multiline
    }
}

/// Язык — таблица данных: слова, комментарии, строки и особые правила.
public struct LanguageDefinition: Sendable, Hashable, Identifiable {
    /// Особые правила, которых нет в словарях.
    public enum Feature: Sendable, Hashable {
        /// Теги `<name attr="…">` (HTML, XML, JSX).
        case markupTags
        /// Строка перед `:` — ключ (JSON).
        case quotedKeys
        /// Слово перед `:` в начале строки — ключ (YAML), перед `=` — ключ, `[раздел]` (TOML).
        case lineKeys
        /// Слово перед `:` внутри `{ }` — свойство (CSS, SCSS).
        case cssProperties
        /// `$имя`, `${…}` — переменная (Bash, PHP, SCSS).
        case dollarVariables
        /// `@имя` — пометка (Swift, Java, Kotlin, Python, CSS `@media`).
        case atAnnotations
        /// `#include` в начале строки (C, C++, C#).
        case preprocessor
        /// Слово с заглавной — тип (Swift, Kotlin, Java, Rust, Go, C#, TypeScript).
        case capitalizedTypes
        /// Заголовки `#`, код в строке `` ` ``, ограды кода (Markdown).
        case markdown
    }

    /// id для `props.language`: `swift`, `python`, … `plain`.
    public var id: String
    /// Название в окне выбора языка.
    public var title: String
    /// Имена из ограды кода Markdown (` ```js `), кроме самого id.
    public var aliases: [String]
    public var keywords: Set<String>
    public var types: Set<String>
    public var literals: Set<String>
    public var lineComments: [String]
    public var blockComments: [(open: String, close: String)]
    public var strings: [StringRule]
    public var features: Set<Feature>
    /// Слова без учёта регистра (SQL).
    public var caseInsensitive: Bool
    /// Знаки, которые бывают внутри слова кроме букв, цифр и `_` (CSS: `-`).
    public var identifierExtras: Set<Character>

    public init(id: String, title: String, aliases: [String] = [], keywords: Set<String> = [], types: Set<String> = [],
                literals: Set<String> = [], lineComments: [String] = [], blockComments: [(open: String, close: String)] = [],
                strings: [StringRule] = [], features: Set<Feature> = [], caseInsensitive: Bool = false,
                identifierExtras: Set<Character> = []) {
        self.id = id
        self.title = title
        self.aliases = aliases
        self.keywords = caseInsensitive ? Set(keywords.map { $0.lowercased() }) : keywords
        self.types = caseInsensitive ? Set(types.map { $0.lowercased() }) : types
        self.literals = caseInsensitive ? Set(literals.map { $0.lowercased() }) : literals
        self.lineComments = lineComments
        self.blockComments = blockComments
        self.strings = strings
        self.features = features
        self.caseInsensitive = caseInsensitive
        self.identifierExtras = identifierExtras
    }

    public static func == (lhs: LanguageDefinition, rhs: LanguageDefinition) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension LanguageDefinition {
    /// «Простой текст»: без подсветки.
    public static let plain = LanguageDefinition(id: "plain", title: "Простой текст", aliases: ["text", "txt", "plaintext", "plain text"])

    /// 24 языка research R5 и «Простой текст» — по порядку окна выбора (как у Notion: по алфавиту, простой текст первым).
    public static let all: [LanguageDefinition] = [
        .plain, .bash, .c, .cpp, .csharp, .css, .go, .html, .java, .javascript, .json, .jsx, .kotlin, .markdown,
        .php, .python, .ruby, .rust, .scss, .sql, .swift, .toml, .typescript, .xml, .yaml,
    ]

    private static let byName: [String: LanguageDefinition] = {
        var names: [String: LanguageDefinition] = [:]
        for language in all {
            for name in [language.id, language.title] + language.aliases where names[name.lowercased()] == nil {
                names[name.lowercased()] = language
            }
        }
        return names
    }()

    /// Язык по id, названию или имени из ограды Markdown; `nil` — незнакомый.
    public static func named(_ name: String) -> LanguageDefinition? {
        byName[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// Язык блока по `props.language`; незнакомый — «Простой текст».
    public static func forBlock(_ id: String?) -> LanguageDefinition {
        id.flatMap(named) ?? .plain
    }
}
