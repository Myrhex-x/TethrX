import SwiftUI

/// Monochrome syntax highlighting for the code the phone has to read: fenced blocks
/// in Grok's replies, file diffs, and the project browser.
///
/// The brand is black and white, so this does not colour tokens — it *ranks* them.
/// Comments recede almost to the background, strings sit below the prose, keywords
/// come forward in weight. The result reads like a terminal with a good theme
/// rather than a Christmas tree, and it survives Dynamic Type because every span
/// keeps the caller's font size and only changes weight and opacity.
enum Syntax {

    // MARK: Token ranking (the whole "palette")

    enum Token {
        case plain, keyword, type, string, number, comment, punctuation

        var opacity: Double {
            switch self {
            case .comment:     return 0.34
            case .string:      return 0.60
            case .number:      return 0.74
            case .punctuation: return 0.50
            case .keyword:     return 1.0
            case .type:        return 1.0
            case .plain:       return 0.88
            }
        }
        var weight: Font.Weight {
            switch self {
            case .keyword: return .semibold
            case .type:    return .medium
            default:       return .regular
            }
        }
    }

    /// Anything longer than this is rendered plain. A 30k-character file is already
    /// past what anyone reads on a phone, and tokenizing it on the main thread while
    /// a turn streams is exactly the hitch the buffered renderer exists to avoid.
    static let limit = 30_000

    /// Highlight `code` as `language`, at `size` points. Returns plain text when the
    /// language is unknown, unsupported, or the input is too long to be worth it.
    static func highlight(_ code: String, language: String, size: CGFloat) -> AttributedString {
        guard code.count <= limit, let grammar = Grammar.named(language) else {
            var plain = AttributedString(code)
            plain.font = Grok.mono(size)
            plain.foregroundColor = Grok.text.opacity(Token.plain.opacity)
            return plain
        }
        var out = AttributedString()
        for (text, token) in tokenize(code, grammar: grammar) {
            var run = AttributedString(text)
            run.font = Grok.mono(size, token.weight)
            run.foregroundColor = Grok.text.opacity(token.opacity)
            out.append(run)
        }
        return out
    }

    /// True when this language has a grammar — callers use it to skip the work
    /// entirely rather than build an attributed string that changes nothing.
    static func supports(_ language: String) -> Bool { Grammar.named(language) != nil }

    /// Guess a fence language from a file name, so diffs and the file browser get
    /// the same treatment as a fenced block Grok wrote by hand.
    static func language(forPath path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        // A few files carry their language in the whole name, not an extension.
        switch name {
        case "dockerfile", "makefile", "brewfile", "podfile", "gemfile", "rakefile": return "sh"
        case "package.json", "tsconfig.json": return "json"
        default: break
        }
        return (name as NSString).pathExtension
    }

    // MARK: Grammar

    struct Grammar {
        var keywords: Set<String>
        var lineComments: [String]
        var blockComment: (open: String, close: String)?
        /// Quote characters that open a single-line string.
        var quotes: Set<Character>
        /// Triple-quote openers (Python docstrings, Swift multiline literals).
        var tripleQuotes: [String]
        /// `#if`, `@available`, `#[derive]` … lead characters that start a keyword-ish run.
        var sigils: Set<Character>

        static func named(_ raw: String) -> Grammar? {
            switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
            case "swift":
                return Grammar(keywords: swiftKeywords, lineComments: ["//"], blockComment: ("/*", "*/"),
                               quotes: ["\""], tripleQuotes: ["\"\"\""], sigils: ["#", "@"])
            case "js", "javascript", "jsx", "mjs", "cjs", "ts", "typescript", "tsx":
                return Grammar(keywords: jsKeywords, lineComments: ["//"], blockComment: ("/*", "*/"),
                               quotes: ["\"", "'", "`"], tripleQuotes: [], sigils: [])
            case "json", "jsonc":
                return Grammar(keywords: ["true", "false", "null"], lineComments: ["//"], blockComment: ("/*", "*/"),
                               quotes: ["\""], tripleQuotes: [], sigils: [])
            case "py", "python":
                return Grammar(keywords: pythonKeywords, lineComments: ["#"], blockComment: nil,
                               quotes: ["\"", "'"], tripleQuotes: ["\"\"\"", "'''"], sigils: ["@"])
            case "rb", "ruby":
                return Grammar(keywords: rubyKeywords, lineComments: ["#"], blockComment: nil,
                               quotes: ["\"", "'"], tripleQuotes: [], sigils: [])
            case "go":
                return Grammar(keywords: goKeywords, lineComments: ["//"], blockComment: ("/*", "*/"),
                               quotes: ["\"", "`"], tripleQuotes: [], sigils: [])
            case "rs", "rust":
                return Grammar(keywords: rustKeywords, lineComments: ["//"], blockComment: ("/*", "*/"),
                               quotes: ["\""], tripleQuotes: [], sigils: ["#"])
            case "c", "h", "cpp", "cc", "hpp", "cxx", "m", "mm", "objc", "java", "kt", "kotlin", "cs", "csharp", "dart", "scala", "groovy", "php":
                return Grammar(keywords: cKeywords, lineComments: ["//"], blockComment: ("/*", "*/"),
                               quotes: ["\"", "'"], tripleQuotes: [], sigils: ["#", "@"])
            case "sh", "bash", "zsh", "shell", "fish", "console", "terminal":
                return Grammar(keywords: shellKeywords, lineComments: ["#"], blockComment: nil,
                               quotes: ["\"", "'"], tripleQuotes: [], sigils: ["$"])
            case "yml", "yaml", "toml", "ini", "conf", "cfg", "properties", "env":
                return Grammar(keywords: ["true", "false", "null", "yes", "no", "on", "off"],
                               lineComments: ["#"], blockComment: nil,
                               quotes: ["\"", "'"], tripleQuotes: [], sigils: [])
            case "sql":
                return Grammar(keywords: sqlKeywords, lineComments: ["--"], blockComment: ("/*", "*/"),
                               quotes: ["'", "\""], tripleQuotes: [], sigils: [])
            case "css", "scss", "sass", "less":
                return Grammar(keywords: [], lineComments: ["//"], blockComment: ("/*", "*/"),
                               quotes: ["\"", "'"], tripleQuotes: [], sigils: ["@"])
            case "html", "htm", "xml", "svg", "vue", "plist", "storyboard", "xib":
                return Grammar(keywords: [], lineComments: [], blockComment: ("<!--", "-->"),
                               quotes: ["\"", "'"], tripleQuotes: [], sigils: [])
            default:
                return nil    // prose, markdown, logs, anything unknown: leave it alone
            }
        }
    }

    // MARK: Tokenizer

    /// One pass, character by character, emitting runs. It is deliberately not a
    /// parser: it knows comments, strings, numbers and word shapes, which is every
    /// distinction the ranking above can actually show.
    private static func tokenize(_ code: String, grammar: Grammar) -> [(String, Token)] {
        var runs: [(String, Token)] = []
        var buffer = ""
        var bufferToken = Token.plain

        func emit(_ text: String, _ token: Token) {
            guard !text.isEmpty else { return }
            if token == bufferToken {
                buffer += text
            } else {
                if !buffer.isEmpty { runs.append((buffer, bufferToken)) }
                buffer = text
                bufferToken = token
            }
        }

        let chars = Array(code)
        var i = 0

        // Delimiters are compared character by character, so turn them into arrays
        // ONCE. Building them inside the match meant one allocation per delimiter per
        // source character — the tokenizer spent most of its time in `Array(String)`.
        let lineOpeners = grammar.lineComments.map(Array.init)
        let blockOpen = grammar.blockComment.map { Array($0.open) }
        let blockClose = grammar.blockComment.map { Array($0.close) }
        let triples = grammar.tripleQuotes.map(Array.init)

        /// Does the source match `needle` at `index`?
        func matches(_ needle: [Character], at index: Int) -> Bool {
            guard index + needle.count <= chars.count else { return false }
            for offset in 0..<needle.count where chars[index + offset] != needle[offset] { return false }
            return true
        }

        while i < chars.count {
            let c = chars[i]

            // Line comment — runs to the end of the line.
            if lineOpeners.contains(where: { matches($0, at: i) }) {
                var j = i
                while j < chars.count, chars[j] != "\n" { j += 1 }
                emit(String(chars[i..<j]), .comment)
                i = j
                continue
            }

            // Block comment — runs to its closer, or to the end if it never closes
            // (which is what a streaming, half-arrived block looks like).
            if let open = blockOpen, let close = blockClose, matches(open, at: i) {
                var j = i + open.count
                while j < chars.count, !matches(close, at: j) { j += 1 }
                let end = min(chars.count, j + (j < chars.count ? close.count : 0))
                emit(String(chars[i..<end]), .comment)
                i = end
                continue
            }

            // Triple-quoted string (docstring / multiline literal).
            if let triple = triples.first(where: { matches($0, at: i) }) {
                var j = i + triple.count
                while j < chars.count, !matches(triple, at: j) { j += 1 }
                let end = min(chars.count, j + (j < chars.count ? triple.count : 0))
                emit(String(chars[i..<end]), .string)
                i = end
                continue
            }

            // Single-line string. Escapes are honoured; an unterminated literal stops
            // at the newline so one stray quote cannot grey out the rest of the file.
            if grammar.quotes.contains(c) {
                var j = i + 1
                while j < chars.count {
                    if chars[j] == "\\" { j += 2; continue }
                    if chars[j] == c { j += 1; break }
                    if chars[j] == "\n", c != "`" { break }
                    j += 1
                }
                emit(String(chars[i..<min(j, chars.count)]), .string)
                i = min(j, chars.count)
                continue
            }

            // Number (including hex, floats, and 1_000_000 style separators).
            if c.isNumber {
                var j = i
                while j < chars.count, chars[j].isHexDigit || chars[j] == "." || chars[j] == "_"
                        || chars[j] == "x" || chars[j] == "X" { j += 1 }
                emit(String(chars[i..<j]), .number)
                i = j
                continue
            }

            // Word: a keyword, a Type, or a plain identifier.
            if c.isLetter || c == "_" || grammar.sigils.contains(c) {
                var j = i
                if grammar.sigils.contains(c) { j += 1 }
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                let bare = grammar.sigils.contains(c) ? String(word.dropFirst()) : word
                if grammar.keywords.contains(bare) || (grammar.sigils.contains(c) && !bare.isEmpty) {
                    emit(word, .keyword)
                } else if let first = bare.first, first.isUppercase {
                    // Capitalized words are types nearly everywhere this app renders,
                    // and where they are not (a shouty constant) medium weight is
                    // still the right emphasis.
                    emit(word, .type)
                } else {
                    emit(word, .plain)
                }
                i = j
                continue
            }

            // Everything else: brackets, operators, whitespace.
            if c.isWhitespace {
                emit(String(c), bufferToken == .comment ? .plain : bufferToken)
            } else {
                emit(String(c), .punctuation)
            }
            i += 1
        }

        if !buffer.isEmpty { runs.append((buffer, bufferToken)) }
        return runs
    }

    // MARK: Keyword sets

    private static let swiftKeywords: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
        "convenience", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false",
        "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in", "indirect", "init", "inout",
        "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated", "open", "operator", "override",
        "private", "protocol", "public", "repeat", "required", "rethrows", "return", "self", "Self", "set",
        "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias",
        "unowned", "var", "weak", "where", "while", "willSet", "didSet",
    ]

    private static let jsKeywords: Set<String> = [
        "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from",
        "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null",
        "of", "private", "protected", "public", "readonly", "return", "satisfies", "set", "static", "super",
        "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield",
    ]

    private static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
        "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None",
        "nonlocal", "not", "or", "pass", "raise", "return", "self", "True", "try", "while", "with", "yield",
    ]

    private static let rubyKeywords: Set<String> = [
        "alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else", "elsif", "end",
        "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "require", "rescue",
        "retry", "return", "self", "super", "then", "true", "unless", "until", "when", "while", "yield",
    ]

    private static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for",
        "func", "go", "goto", "if", "import", "interface", "map", "nil", "package", "range", "return", "select",
        "struct", "switch", "true", "type", "var",
    ]

    private static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false",
        "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
        "self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
    ]

    private static let cKeywords: Set<String> = [
        "abstract", "auto", "bool", "break", "case", "catch", "char", "class", "companion", "const", "constexpr",
        "continue", "data", "default", "delete", "do", "double", "else", "enum", "explicit", "extends", "extern",
        "false", "final", "finally", "float", "for", "friend", "fun", "goto", "if", "implements", "import", "in",
        "inline", "instanceof", "int", "interface", "internal", "is", "lateinit", "let", "long", "namespace",
        "new", "nil", "null", "nullptr", "object", "operator", "override", "package", "private", "protected",
        "public", "return", "short", "signed", "sizeof", "static", "struct", "super", "suspend", "switch",
        "template", "this", "throw", "throws", "true", "try", "typedef", "typename", "union", "unsigned", "using",
        "val", "var", "virtual", "void", "volatile", "when", "while",
    ]

    private static let shellKeywords: Set<String> = [
        "case", "cd", "do", "done", "echo", "elif", "else", "esac", "exit", "export", "fi", "for", "function",
        "if", "in", "local", "return", "set", "shift", "source", "then", "unset", "until", "while",
    ]

    private static let sqlKeywords: Set<String> = [
        "alter", "and", "as", "asc", "begin", "between", "by", "case", "commit", "create", "delete", "desc",
        "distinct", "drop", "else", "end", "exists", "from", "group", "having", "if", "in", "index", "inner",
        "insert", "into", "join", "left", "like", "limit", "not", "null", "on", "or", "order", "outer", "primary",
        "rollback", "select", "set", "table", "then", "truncate", "union", "update", "values", "when", "where",
    ]
}
