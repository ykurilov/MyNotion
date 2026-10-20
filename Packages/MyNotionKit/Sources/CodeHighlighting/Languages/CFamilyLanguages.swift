/// Языки со скобками и `//`: Swift, C, C++, C#, Java, Kotlin, Go, Rust.
extension LanguageDefinition {
    static let cStrings = [StringRule("\""), StringRule("'")]
    static let cComments: [(open: String, close: String)] = [("/*", "*/")]

    public static let swift = LanguageDefinition(
        id: "swift", title: "Swift",
        keywords: ["actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default",
                   "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "fileprivate", "final", "for", "func",
                   "guard", "if", "import", "in", "init", "inout", "internal", "is", "lazy", "let", "mutating", "nonisolated",
                   "open", "operator", "override", "private", "protocol", "public", "repeat", "rethrows", "return", "self",
                   "Self", "some", "any", "static", "struct", "subscript", "super", "switch", "throw", "throws", "try", "typealias",
                   "var", "weak", "unowned", "where", "while", "convenience", "required", "dynamic", "indirect", "get", "set",
                   "willSet", "didSet", "consuming", "borrowing", "sending"],
        types: ["Int", "Double", "Float", "String", "Bool", "Character", "Array", "Dictionary", "Set", "Optional", "Void", "Never",
                "UInt", "Int64", "Int32", "CGFloat", "Data", "URL", "UUID", "Date", "Result", "Error"],
        literals: ["true", "false", "nil"],
        lineComments: ["//"], blockComments: cComments,
        strings: [StringRule("\"\"\"", multiline: true), StringRule("\"")],
        features: [.atAnnotations, .capitalizedTypes, .preprocessor]
    )

    public static let c = LanguageDefinition(
        id: "c", title: "C", aliases: ["h"],
        keywords: ["auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for", "goto", "if",
                   "inline", "register", "restrict", "return", "sizeof", "static", "struct", "switch", "typedef", "union",
                   "volatile", "while"],
        types: ["char", "double", "float", "int", "long", "short", "signed", "unsigned", "void", "size_t", "bool", "uint8_t",
                "uint32_t", "int32_t", "int64_t", "FILE"],
        literals: ["NULL", "true", "false"],
        lineComments: ["//"], blockComments: cComments, strings: cStrings,
        features: [.preprocessor]
    )

    public static let cpp = LanguageDefinition(
        id: "cpp", title: "C++", aliases: ["c++", "cc", "cxx", "hpp"],
        keywords: c.keywords.union(["alignas", "catch", "class", "constexpr", "consteval", "decltype", "delete", "explicit",
                                    "friend", "mutable", "namespace", "new", "noexcept", "operator", "override", "private",
                                    "protected", "public", "template", "this", "throw", "try", "typename", "using", "virtual",
                                    "final", "co_await", "co_return", "static_cast", "dynamic_cast", "reinterpret_cast", "const_cast"]),
        types: c.types.union(["string", "vector", "map", "auto", "wchar_t", "std"]),
        literals: ["nullptr", "NULL", "true", "false"],
        lineComments: ["//"], blockComments: cComments, strings: cStrings,
        features: [.preprocessor]
    )

    public static let csharp = LanguageDefinition(
        id: "csharp", title: "C#", aliases: ["c#", "cs"],
        keywords: ["abstract", "as", "async", "await", "base", "break", "case", "catch", "checked", "class", "const", "continue",
                   "default", "delegate", "do", "else", "enum", "event", "explicit", "extern", "finally", "fixed", "for", "foreach",
                   "get", "goto", "if", "implicit", "in", "init", "interface", "internal", "is", "lock", "namespace", "new",
                   "operator", "out", "override", "params", "private", "protected", "public", "readonly", "record", "ref",
                   "return", "sealed", "set", "sizeof", "stackalloc", "static", "struct", "switch", "this", "throw", "try",
                   "typeof", "unsafe", "using", "var", "virtual", "volatile", "where", "while", "yield"],
        types: ["bool", "byte", "char", "decimal", "double", "dynamic", "float", "int", "long", "object", "sbyte", "short",
                "string", "uint", "ulong", "ushort", "void"],
        literals: ["true", "false", "null"],
        lineComments: ["//"], blockComments: cComments,
        strings: [StringRule("@\"", "\"", escape: nil, multiline: true), StringRule("\""), StringRule("'")],
        features: [.preprocessor, .capitalizedTypes]
    )

    public static let java = LanguageDefinition(
        id: "java", title: "Java",
        keywords: ["abstract", "assert", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "enum",
                   "extends", "final", "finally", "for", "goto", "if", "implements", "import", "instanceof", "interface",
                   "native", "new", "package", "private", "protected", "public", "return", "static", "strictfp", "super",
                   "switch", "synchronized", "this", "throw", "throws", "transient", "try", "var", "volatile", "while",
                   "record", "sealed", "permits", "yield"],
        types: ["boolean", "byte", "char", "double", "float", "int", "long", "short", "void", "String", "Integer", "Object",
                "List", "Map"],
        literals: ["true", "false", "null"],
        lineComments: ["//"], blockComments: cComments,
        strings: [StringRule("\"\"\"", multiline: true), StringRule("\""), StringRule("'")],
        features: [.atAnnotations, .capitalizedTypes]
    )

    public static let kotlin = LanguageDefinition(
        id: "kotlin", title: "Kotlin", aliases: ["kt", "kts"],
        keywords: ["abstract", "annotation", "as", "break", "by", "catch", "class", "companion", "const", "constructor",
                   "continue", "crossinline", "data", "do", "else", "enum", "external", "final", "finally", "for", "fun", "get",
                   "if", "import", "in", "infix", "init", "inline", "inner", "interface", "internal", "is", "lateinit",
                   "noinline", "object", "open", "operator", "out", "override", "package", "private", "protected", "public",
                   "reified", "return", "sealed", "set", "super", "suspend", "this", "throw", "try", "typealias", "val", "var",
                   "vararg", "when", "where", "while"],
        types: ["Int", "Long", "Double", "Float", "String", "Boolean", "Char", "Unit", "Any", "Nothing", "List", "Map", "Array"],
        literals: ["true", "false", "null"],
        lineComments: ["//"], blockComments: cComments,
        strings: [StringRule("\"\"\"", escape: nil, multiline: true), StringRule("\""), StringRule("'")],
        features: [.atAnnotations, .capitalizedTypes, .dollarVariables]
    )

    public static let go = LanguageDefinition(
        id: "go", title: "Go", aliases: ["golang"],
        keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go",
                   "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch",
                   "type", "var"],
        types: ["bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16", "int32",
                "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any"],
        literals: ["true", "false", "nil", "iota"],
        lineComments: ["//"], blockComments: cComments,
        strings: [StringRule("`", escape: nil, multiline: true), StringRule("\""), StringRule("'")],
        features: [.capitalizedTypes]
    )

    public static let rust = LanguageDefinition(
        id: "rust", title: "Rust", aliases: ["rs"],
        keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn", "for",
                   "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self",
                   "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while"],
        types: ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64", "bool",
                "char", "str", "String", "Vec", "Option", "Result", "Box"],
        literals: ["true", "false", "None", "Some", "Ok", "Err"],
        lineComments: ["//"], blockComments: cComments,
        strings: [StringRule("\"", multiline: true)],
        features: [.capitalizedTypes]
    )
}
