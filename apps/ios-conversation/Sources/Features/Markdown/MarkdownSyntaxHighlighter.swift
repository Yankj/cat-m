import Foundation

/// Lightweight regex tokenizer for fenced code. Line-oriented on purpose: a streaming code block
/// only tokenizes its newest lines (earlier lines hit the cache), and block comments / multi-line
/// strings are approximated per line.
enum MarkdownSyntaxToken: Sendable, Equatable { case keyword, string, number, comment, type, literal }

struct MarkdownSyntaxSpan: Sendable, Equatable {
    let range: NSRange
    let token: MarkdownSyntaxToken
}

enum MarkdownSyntaxHighlighter {
    struct Grammar: Sendable {
        let keywords: Set<String>
        let literals: Set<String>
        let lineComment: [String]
        let hashComment: Bool
        let typesCapitalized: Bool
    }

    static func normalize(_ language: String) -> String {
        let l = language.lowercased()
        switch l {
        case "js", "javascript", "jsx", "mjs", "cjs": return "js"
        case "ts", "typescript", "tsx": return "ts"
        case "py", "python", "python3": return "python"
        case "sh", "bash", "zsh", "shell", "console", "shellsession": return "bash"
        case "golang", "go": return "go"
        case "kt", "kotlin": return "kotlin"
        case "objc", "objective-c", "c", "cpp", "c++", "h", "hpp", "cc": return "c"
        case "yml", "yaml": return "yaml"
        case "rs", "rust": return "rust"
        case "rb", "ruby": return "ruby"
        case "jsonc", "json5", "json": return "json"
        case "sql", "postgres", "postgresql", "sqlite": return "sql"
        case "java": return "java"
        case "swift": return "swift"
        default: return l
        }
    }

    static func grammar(for language: String) -> Grammar? {
        let common: Set<String> = ["if", "else", "for", "while", "return", "break", "continue", "switch", "case", "default", "do", "try", "catch", "throw", "in", "import"]
        func g(_ k: [String], literals: [String] = ["true", "false", "null"], slash: Bool = true, hash: Bool = false, types: Bool = true) -> Grammar {
            Grammar(keywords: common.union(k), literals: Set(literals), lineComment: slash ? ["//"] : [], hashComment: hash, typesCapitalized: types)
        }
        switch normalize(language) {
        case "swift": return g(["let", "var", "func", "struct", "class", "enum", "protocol", "extension", "guard", "defer", "async", "await", "throws", "rethrows", "some", "any", "self", "Self", "init", "deinit", "static", "private", "fileprivate", "public", "internal", "open", "final", "override", "mutating", "where", "as", "is", "typealias", "associatedtype", "inout", "actor", "nonisolated", "lazy", "weak", "unowned", "repeat", "fallthrough", "subscript", "get", "set", "willSet", "didSet"], literals: ["true", "false", "nil"])
        case "js", "ts": return g(["const", "let", "var", "function", "class", "extends", "new", "this", "super", "async", "await", "yield", "export", "from", "of", "typeof", "instanceof", "delete", "void", "finally", "interface", "type", "implements", "enum", "readonly", "public", "private", "protected", "static", "as", "keyof", "declare", "namespace"], literals: ["true", "false", "null", "undefined", "NaN"])
        case "python": return g(["def", "class", "lambda", "pass", "with", "as", "from", "global", "nonlocal", "yield", "async", "await", "and", "or", "not", "is", "elif", "except", "finally", "raise", "assert", "del", "self"], literals: ["True", "False", "None"], slash: false, hash: true)
        case "go": return g(["package", "func", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "select", "range", "fallthrough", "goto"], literals: ["true", "false", "nil", "iota"])
        case "bash": return g(["then", "fi", "elif", "esac", "done", "function", "local", "export", "echo", "cd", "sudo", "set", "unset", "source", "exit", "until"], literals: [], slash: false, hash: true, types: false)
        case "json": return g([], literals: ["true", "false", "null"], slash: true, types: false)
        case "yaml": return g([], literals: ["true", "false", "null", "yes", "no"], slash: false, hash: true, types: false)
        case "rust": return g(["fn", "let", "mut", "struct", "enum", "impl", "trait", "pub", "use", "mod", "match", "loop", "where", "as", "ref", "move", "async", "await", "self", "Self", "crate", "super", "dyn", "unsafe", "const", "static", "type"], literals: ["true", "false", "None", "Some", "Ok", "Err"])
        case "kotlin", "java", "c": return g(["val", "var", "fun", "class", "object", "interface", "public", "private", "protected", "static", "final", "void", "int", "long", "double", "float", "char", "bool", "boolean", "struct", "const", "new", "this", "extends", "implements", "override", "package", "when", "typedef", "sizeof", "unsigned", "include", "define", "namespace", "template", "auto"], literals: ["true", "false", "null", "nil", "NULL", "nullptr"])
        case "ruby": return g(["def", "end", "class", "module", "do", "unless", "elsif", "then", "yield", "self", "begin", "rescue", "ensure", "require", "attr_accessor"], literals: ["true", "false", "nil"], slash: false, hash: true)
        case "sql": return Grammar(keywords: ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AND", "OR", "NOT", "NULL", "AS", "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "PRIMARY", "KEY", "REFERENCES", "INDEX", "DISTINCT", "UNION", "RETURNING", "WITH", "IN", "IS", "DEFAULT", "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "join", "on", "and", "or", "not", "as", "order", "by", "group", "limit", "with"], literals: ["TRUE", "FALSE", "true", "false"], lineComment: ["--"], hashComment: false, typesCapitalized: false)
        default: return nil
        }
    }

    private static let stringPattern = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?|`(?:[^`\\]|\\.)*`?"#)
    private static let numberPattern = try! NSRegularExpression(pattern: #"\b(?:0x[0-9A-Fa-f_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#)
    private static let wordPattern = try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#)

    /// Token spans for one line (UTF-16 ranges into `line`).
    static func spans(line: String, language: String) -> [MarkdownSyntaxSpan] {
        guard let grammar = grammar(for: language) else { return [] }
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        var spans: [MarkdownSyntaxSpan] = []
        var covered = IndexSet()
        func add(_ r: NSRange, _ t: MarkdownSyntaxToken) {
            guard r.length > 0, !covered.intersects(integersIn: r.location..<(r.location + r.length)) else { return }
            covered.insert(integersIn: r.location..<(r.location + r.length))
            spans.append(MarkdownSyntaxSpan(range: r, token: t))
        }
        // Strings first (so comment markers inside strings are ignored), then comments from the first
        // marker outside a string, then numbers and words.
        let strings = stringPattern.matches(in: line, range: full).map(\.range)
        var commentStart: Int?
        for marker in grammar.lineComment + (grammar.hashComment ? ["#"] : []) {
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let r = ns.range(of: marker, options: [], range: search)
                if r.location == NSNotFound { break }
                if !strings.contains(where: { NSLocationInRange(r.location, $0) }) {
                    commentStart = min(commentStart ?? r.location, r.location); break
                }
                search = NSRange(location: r.location + r.length, length: ns.length - r.location - r.length)
            }
        }
        if let c = commentStart { add(NSRange(location: c, length: ns.length - c), .comment) }
        for r in strings { add(r, .string) }
        for m in numberPattern.matches(in: line, range: full) { add(m.range, .number) }
        for m in wordPattern.matches(in: line, range: full) {
            let word = ns.substring(with: m.range)
            if grammar.keywords.contains(word) { add(m.range, .keyword) }
            else if grammar.literals.contains(word) { add(m.range, .literal) }
            else if grammar.typesCapitalized, let f = word.first, f.isUppercase, word.count > 1 { add(m.range, .type) }
        }
        return spans.sorted { $0.range.location < $1.range.location }
    }
}
