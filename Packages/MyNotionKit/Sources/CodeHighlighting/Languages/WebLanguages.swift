/// Языки веба: JavaScript, TypeScript, JSX/TSX, HTML, XML, CSS, SCSS, JSON, PHP.
extension LanguageDefinition {
    static let javascriptKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else",
        "export", "extends", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "let", "new", "of",
        "return", "static", "super", "switch", "this", "throw", "try", "typeof", "var", "void", "while", "with", "yield", "get", "set",
    ]
    static let javascriptStrings = [StringRule("`", multiline: true), StringRule("\""), StringRule("'")]
    static let typescriptKeywords = javascriptKeywords.union([
        "abstract", "as", "declare", "enum", "implements", "interface", "keyof", "namespace", "private", "protected", "public",
        "readonly", "satisfies", "type", "infer", "is", "override",
    ])
    static let typescriptTypes: Set<String> = ["any", "boolean", "never", "number", "object", "string", "symbol", "unknown", "bigint",
                                               "Promise", "Array", "Record", "Partial"]

    public static let javascript = LanguageDefinition(
        id: "javascript", title: "JavaScript", aliases: ["js", "mjs", "cjs", "node"],
        keywords: javascriptKeywords, literals: ["true", "false", "null", "undefined", "NaN"],
        lineComments: ["//"], blockComments: cComments, strings: javascriptStrings
    )

    public static let typescript = LanguageDefinition(
        id: "typescript", title: "TypeScript", aliases: ["ts"],
        keywords: typescriptKeywords, types: typescriptTypes, literals: ["true", "false", "null", "undefined"],
        lineComments: ["//"], blockComments: cComments, strings: javascriptStrings,
        features: [.atAnnotations, .capitalizedTypes]
    )

    /// JSX и TSX — одним языком: JavaScript с типами TypeScript и тегами.
    public static let jsx = LanguageDefinition(
        id: "jsx", title: "JSX/TSX", aliases: ["tsx", "react"],
        keywords: typescriptKeywords, types: typescriptTypes, literals: ["true", "false", "null", "undefined"],
        lineComments: ["//"], blockComments: cComments, strings: javascriptStrings,
        features: [.markupTags]
    )

    public static let html = LanguageDefinition(
        id: "html", title: "HTML", aliases: ["htm", "xhtml"],
        blockComments: [("<!--", "-->")],
        features: [.markupTags]
    )

    public static let xml = LanguageDefinition(
        id: "xml", title: "XML", aliases: ["plist", "svg", "xsd"],
        blockComments: [("<!--", "-->")],
        features: [.markupTags]
    )

    public static let css = LanguageDefinition(
        id: "css", title: "CSS",
        keywords: ["important", "from", "to", "and", "not", "only"],
        lineComments: [], blockComments: cComments, strings: [StringRule("\""), StringRule("'")],
        features: [.cssProperties, .atAnnotations], identifierExtras: ["-"]
    )

    public static let scss = LanguageDefinition(
        id: "scss", title: "SCSS", aliases: ["sass"],
        keywords: ["important", "from", "to", "and", "not", "only", "if", "else", "each", "for", "in", "while", "return"],
        lineComments: ["//"], blockComments: cComments, strings: [StringRule("\""), StringRule("'")],
        features: [.cssProperties, .atAnnotations, .dollarVariables], identifierExtras: ["-"]
    )

    public static let json = LanguageDefinition(
        id: "json", title: "JSON", aliases: ["jsonc", "json5"],
        literals: ["true", "false", "null"],
        lineComments: ["//"], blockComments: cComments, strings: [StringRule("\"")],
        features: [.quotedKeys]
    )

    public static let php = LanguageDefinition(
        id: "php", title: "PHP",
        keywords: ["abstract", "and", "array", "as", "break", "case", "catch", "class", "clone", "const", "continue", "declare",
                   "default", "do", "echo", "else", "elseif", "empty", "enum", "extends", "final", "finally", "fn", "for",
                   "foreach", "function", "global", "if", "implements", "include", "instanceof", "interface", "isset", "list",
                   "match", "namespace", "new", "or", "print", "private", "protected", "public", "readonly", "require",
                   "return", "static", "switch", "throw", "trait", "try", "unset", "use", "var", "while", "yield"],
        types: ["int", "float", "string", "bool", "void", "mixed", "object", "iterable", "callable"],
        literals: ["true", "false", "null", "TRUE", "FALSE", "NULL"],
        lineComments: ["//", "#"], blockComments: cComments,
        strings: [StringRule("\"", multiline: true), StringRule("'", multiline: true)],
        features: [.dollarVariables, .capitalizedTypes]
    )
}
