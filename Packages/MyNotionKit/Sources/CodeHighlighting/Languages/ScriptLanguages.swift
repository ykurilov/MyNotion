/// Языки сценариев и данных: Python, Ruby, Bash, SQL, Markdown, YAML, TOML.
extension LanguageDefinition {
    public static let python = LanguageDefinition(
        id: "python", title: "Python", aliases: ["py", "python3"],
        keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except",
                   "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass",
                   "raise", "return", "try", "while", "with", "yield", "match", "case", "self"],
        types: ["int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes", "object", "type", "print", "len",
                "range", "open"],
        literals: ["True", "False", "None"],
        lineComments: ["#"],
        strings: [StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), StringRule("\""), StringRule("'")],
        features: [.atAnnotations]
    )

    public static let ruby = LanguageDefinition(
        id: "ruby", title: "Ruby", aliases: ["rb"],
        keywords: ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure",
                   "for", "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry", "return", "self", "super",
                   "then", "undef", "unless", "until", "when", "while", "yield", "require", "attr_accessor", "puts"],
        literals: ["true", "false", "nil"],
        lineComments: ["#"], blockComments: [("=begin", "=end")],
        strings: [StringRule("\"", multiline: true), StringRule("'", multiline: true)],
        features: [.capitalizedTypes]
    )

    public static let bash = LanguageDefinition(
        id: "bash", title: "Bash/Shell", aliases: ["sh", "shell", "zsh", "console", "shellscript"],
        keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function",
                   "return", "local", "export", "readonly", "declare", "set", "unset", "shift", "exit", "source", "alias",
                   "echo", "cd", "test", "eval", "exec", "trap"],
        literals: ["true", "false"],
        lineComments: ["#"],
        strings: [StringRule("\"", multiline: true), StringRule("'", escape: nil, multiline: true)],
        features: [.dollarVariables], identifierExtras: ["-"]
    )

    public static let sql = LanguageDefinition(
        id: "sql", title: "SQL", aliases: ["mysql", "postgresql", "postgres", "sqlite", "plsql"],
        keywords: ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop",
                   "alter", "add", "index", "view", "join", "left", "right", "inner", "outer", "full", "on", "as", "and", "or",
                   "not", "in", "is", "like", "between", "group", "by", "order", "having", "limit", "offset", "distinct",
                   "union", "all", "exists", "case", "when", "then", "else", "end", "primary", "key", "foreign", "references",
                   "default", "unique", "constraint", "begin", "commit", "rollback", "transaction", "with", "returning",
                   "asc", "desc", "if", "trigger", "conflict", "do", "nothing"],
        types: ["int", "integer", "bigint", "smallint", "text", "varchar", "char", "boolean", "date", "timestamp", "real",
                "float", "double", "numeric", "decimal", "blob", "uuid", "json", "jsonb", "serial"],
        literals: ["null", "true", "false"],
        lineComments: ["--"], blockComments: cComments,
        strings: [StringRule("'", escape: nil), StringRule("\"", escape: nil)],
        caseInsensitive: true
    )

    public static let markdown = LanguageDefinition(
        id: "markdown", title: "Markdown", aliases: ["md"],
        blockComments: [("<!--", "-->")],
        features: [.markdown]
    )

    public static let yaml = LanguageDefinition(
        id: "yaml", title: "YAML", aliases: ["yml"],
        literals: ["true", "false", "null", "yes", "no", "on", "off", "~"],
        lineComments: ["#"],
        strings: [StringRule("\""), StringRule("'", escape: nil)],
        features: [.lineKeys], identifierExtras: ["-", "."]
    )

    public static let toml = LanguageDefinition(
        id: "toml", title: "TOML",
        literals: ["true", "false"],
        lineComments: ["#"],
        strings: [StringRule("\"\"\"", multiline: true), StringRule("'''", escape: nil, multiline: true), StringRule("\""),
                  StringRule("'", escape: nil)],
        features: [.lineKeys], identifierExtras: ["-", "."]
    )
}
