import Foundation

/// 代码块的语法着色。
///
/// 只做「够看」的级别：注释、字符串、数字、关键字、常见内建类型。
/// 不追求编译器级正确——目的是让一段配置或代码在答案里能一眼分出结构。
public enum CodeTokenKind: Equatable, Sendable {
    case plain
    case keyword
    case string
    case comment
    case number
    case type
}

public struct CodeToken: Equatable, Sendable {
    public let text: String
    public let kind: CodeTokenKind

    public init(_ text: String, _ kind: CodeTokenKind) {
        self.text = text
        self.kind = kind
    }
}

public enum CodeHighlighter {
    /// 一门语言的规则：注释符号 + 关键字表
    struct Profile {
        var lineComments: [String] = ["//"]
        var blockComment: (open: String, close: String)? = ("/*", "*/")
        var keywords: Set<String> = []
        var types: Set<String> = []
        var stringQuotes: Set<Character> = ["\"", "'"]
        /// 反引号当字符串（JS 模板串、shell 命令替换）
        var usesBacktick = false
    }

    public static func tokens(_ code: String, language: String) -> [CodeToken] {
        guard !code.isEmpty else { return [] }
        // 不认识的语言就原样返回，不要给普通文字上色
        guard let profile = profile(for: language) else { return [CodeToken(code, .plain)] }
        var tokens: [CodeToken] = []
        var plain = ""
        let chars = Array(code)
        var index = 0

        func flushPlain() {
            guard !plain.isEmpty else { return }
            tokens.append(CodeToken(plain, .plain))
            plain = ""
        }

        func emit(_ text: String, _ kind: CodeTokenKind) {
            flushPlain()
            tokens.append(CodeToken(text, kind))
        }

        while index < chars.count {
            let char = chars[index]

            // 行注释：一路吃到换行
            if let marker = profile.lineComments.first(where: { matches($0, at: index, in: chars) }) {
                flushPlain()
                var end = index
                while end < chars.count, chars[end] != "\n" { end += 1 }
                emit(String(chars[index..<end]), .comment)
                index = end
                _ = marker
                continue
            }

            // 块注释：没闭合就吃到文末，不会吞掉别的 token
            if let block = profile.blockComment, matches(block.open, at: index, in: chars) {
                flushPlain()
                var end = index + block.open.count
                while end < chars.count, !matches(block.close, at: end, in: chars) { end += 1 }
                end = min(chars.count, end + block.close.count)
                emit(String(chars[index..<end]), .comment)
                index = end
                continue
            }

            // 字符串：允许反斜杠转义；没闭合就在行尾收住，避免整段变色
            if profile.stringQuotes.contains(char) || (profile.usesBacktick && char == "`") {
                flushPlain()
                let quote = char
                var end = index + 1
                var escaped = false
                while end < chars.count {
                    let current = chars[end]
                    if escaped {
                        escaped = false
                    } else if current == "\\" {
                        escaped = true
                    } else if current == quote {
                        end += 1
                        break
                    } else if current == "\n" {
                        break
                    }
                    end += 1
                }
                emit(String(chars[index..<end]), .string)
                index = end
                continue
            }

            // 数字：0x / 小数 / 普通的整数
            if char.isNumber {
                flushPlain()
                var end = index
                while end < chars.count, chars[end].isNumber || chars[end].isHexDigit
                    || chars[end] == "." || chars[end] == "_" {
                    end += 1
                }
                emit(String(chars[index..<end]), .number)
                index = end
                continue
            }

            // 标识符：关键字 / 内建类型 / 普通文本
            if char.isLetter || char == "_" {
                var end = index
                while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" {
                    end += 1
                }
                let word = String(chars[index..<end])
                if profile.keywords.contains(word.lowercased()) {
                    emit(word, .keyword)
                } else if profile.types.contains(word) {
                    emit(word, .type)
                } else {
                    plain += word
                }
                index = end
                continue
            }

            plain.append(char)
            index += 1
        }

        flushPlain()
        return tokens
    }

    private static func matches(_ marker: String, at index: Int, in chars: [Character]) -> Bool {
        guard !marker.isEmpty, index + marker.count <= chars.count else { return false }
        for (offset, character) in marker.enumerated() where chars[index + offset] != character {
            return false
        }
        return true
    }

    // MARK: - 语言规则

    private static func profile(for language: String) -> Profile? {
        switch language.lowercased() {
        case "swift":
            return Profile(keywords: swiftKeywords, types: swiftTypes)
        case "python", "py":
            var profile = Profile(lineComments: ["#"], blockComment: nil,
                                  keywords: pythonKeywords, types: pythonTypes)
            profile.stringQuotes = ["\"", "'"]
            return profile
        case "javascript", "js", "jsx", "typescript", "ts", "tsx":
            var profile = Profile(keywords: jsKeywords)
            profile.usesBacktick = true
            return profile
        case "json", "jsonc":
            var profile = Profile(lineComments: ["//"], keywords: ["true", "false", "null"])
            profile.stringQuotes = ["\""]
            return profile
        case "bash", "sh", "shell", "zsh", "console", "shell-session":
            return Profile(lineComments: ["#"], blockComment: nil, keywords: shellKeywords)
        case "go", "golang":
            return Profile(keywords: goKeywords, types: goTypes)
        case "rust", "rs":
            return Profile(keywords: rustKeywords, types: [])
        case "java", "c", "cpp", "c++", "h", "m", "mm", "kotlin", "scala", "csharp", "cs":
            return Profile(keywords: cKeywords, types: cTypes)
        case "sql":
            return Profile(lineComments: ["--"], blockComment: nil,
                           keywords: sqlKeywords, types: [], stringQuotes: ["'"])
        case "yaml", "yml", "toml", "ini":
            return Profile(lineComments: ["#"], blockComment: nil, keywords: ["true", "false", "null"])
        case "nginx", "conf":
            return Profile(lineComments: ["#"], blockComment: nil, keywords: nginxKeywords)
        case "html", "xml", "svg", "css", "scss":
            // 这几类没有「关键字」，只把注释和字符串挑出来，免得满屏乱七八糟
            return Profile(lineComments: [], blockComment: ("<!--", "-->"), keywords: [])
        default:
            return nil
        }
    }

    private static let swiftKeywords: Set<String> = [
        "func", "let", "var", "if", "else", "guard", "return", "for", "in", "while", "switch",
        "case", "default", "struct", "class", "enum", "protocol", "extension", "import", "public",
        "private", "fileprivate", "internal", "static", "final", "override", "init", "deinit",
        "self", "nil", "true", "false", "try", "catch", "throw", "throws", "async", "await",
        "actor", "some", "any", "where", "defer", "repeat", "break", "continue", "fallthrough",
        "typealias", "associatedtype", "mutating", "lazy", "weak", "unowned", "inout", "is", "as",
    ]

    private static let swiftTypes: Set<String> = [
        "Int", "Double", "Float", "String", "Bool", "Array", "Dictionary", "Set", "Optional",
        "Any", "Void", "CGFloat", "URL", "Data", "Error", "Date",
    ]

    private static let pythonKeywords: Set<String> = [
        "def", "class", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is",
        "return", "yield", "import", "from", "as", "pass", "break", "continue", "try", "except",
        "finally", "raise", "with", "lambda", "global", "nonlocal", "assert", "del", "async",
        "await", "true", "false", "none",
    ]

    private static let pythonTypes: Set<String> = [
        "int", "str", "float", "bool", "list", "dict", "set", "tuple", "len", "range",
        "print", "open", "super", "type",
    ]

    private static let jsKeywords: Set<String> = [
        "const", "let", "var", "function", "return", "if", "else", "for", "while", "do",
        "switch", "case", "break", "continue", "new", "class", "extends", "super", "this",
        "import", "export", "from", "default", "async", "await", "try", "catch", "finally",
        "throw", "typeof", "instanceof", "in", "of", "delete", "void", "yield", "static",
        "interface", "type", "enum", "implements", "public", "private", "protected", "readonly",
        "null", "undefined", "true", "false",
    ]

    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until",
        "case", "esac", "function", "return", "export", "local", "readonly", "echo", "cd",
        "source", "alias", "unset", "shift", "exit", "set", "trap", "test",
    ]

    private static let goKeywords: Set<String> = [
        "package", "import", "func", "var", "const", "type", "struct", "interface", "map",
        "chan", "go", "defer", "select", "case", "default", "if", "else", "for", "range",
        "return", "break", "continue", "switch", "fallthrough", "goto", "nil", "true", "false",
    ]

    private static let goTypes: Set<String> = [
        "string", "int", "int64", "float64", "bool", "byte", "rune", "error",
    ]

    private static let rustKeywords: Set<String> = [
        "fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "for", "in",
        "while", "loop", "if", "else", "match", "return", "use", "mod", "pub", "crate", "self",
        "as", "where", "unsafe", "async", "await", "move", "ref", "dyn", "true", "false",
    ]

    private static let cKeywords: Set<String> = [
        "public", "private", "protected", "class", "interface", "extends", "implements",
        "static", "final", "void", "int", "long", "double", "float", "char", "boolean", "if",
        "else", "for", "while", "do", "switch", "case", "return", "new", "this", "super",
        "import", "package", "try", "catch", "finally", "throw", "throws", "abstract",
        "synchronized", "volatile", "native", "null", "true", "false", "struct", "typedef",
        "unsigned", "signed", "sizeof", "include", "define", "const", "extern", "inline",
        "namespace", "template", "typename", "using", "virtual", "override", "delete", "enum",
        "union", "goto", "auto", "break", "continue",
    ]

    private static let cTypes: Set<String> = [
        "String", "Integer", "Double", "Boolean", "List", "Map", "Object", "size_t", "uint32_t",
    ]

    private static let nginxKeywords: Set<String> = [
        "server", "location", "listen", "server_name", "root", "index", "try_files", "return",
        "rewrite", "include", "upstream", "proxy_pass", "proxy_set_header", "proxy_redirect",
        "proxy_http_version", "proxy_read_timeout", "proxy_connect_timeout", "proxy_buffering",
        "add_header", "ssl_certificate", "ssl_certificate_key", "ssl_protocols", "ssl_ciphers",
        "client_max_body_size", "keepalive_timeout", "sendfile", "gzip", "gzip_types",
        "error_page", "access_log", "error_log", "worker_processes", "events", "http",
        "if", "set", "deny", "allow", "auth_basic", "limit_req",
    ]

    private static let sqlKeywords: Set<String> = [
        "select", "from", "where", "join", "left", "right", "inner", "outer", "on", "group",
        "by", "order", "having", "limit", "offset", "insert", "into", "values", "update", "set",
        "delete", "create", "table", "index", "view", "drop", "alter", "add", "column",
        "primary", "key", "foreign", "references", "not", "null", "and", "or", "in", "as",
        "distinct", "count", "sum", "avg", "min", "max", "case", "when", "then", "else", "end",
        "union", "all", "exists", "between", "like", "is",
    ]
}
