import XCTest
@testable import SprigCore

final class CodeHighlighterTests: XCTestCase {
    /// 最要紧的一条：着色只能改颜色，不能改内容
    func testTokensRebuildOriginalText() {
        let samples: [(String, String)] = [
            ("swift", "let x = 1 // 注释\nfunc f() throws -> Int { try g() }"),
            ("python", "def f(a, b=2):\n    # 说明\n    return \"x\" + str(a)"),
            ("json", "{\"a\": 1, \"b\": true, \"c\": null}"),
            ("bash", "if [ -f x ]; then\n  echo \"ok\"\nfi"),
            ("", "SELECT * FROM t WHERE a = 'b'"),
        ]
        for (language, code) in samples {
            XCTAssertEqual(CodeHighlighter.tokens(code, language: language).map(\.text).joined(), code,
                           "语言 \(language) 拼回来不一致")
        }
    }

    func testSwiftTokens() {
        let tokens = CodeHighlighter.tokens("let name = \"知枝\" // 名字\nfunc run() {}", language: "swift")
        XCTAssertTrue(tokens.contains(CodeToken("let", .keyword)))
        XCTAssertTrue(tokens.contains(CodeToken("\"知枝\"", .string)))
        XCTAssertTrue(tokens.contains { $0.kind == .comment && $0.text.hasPrefix("// 名字") })
        XCTAssertTrue(tokens.contains(CodeToken("func", .keyword)))
    }

    func testPythonCommentAndKeyword() {
        let tokens = CodeHighlighter.tokens("# 注释\nimport os\n\ndef f():\n    return None", language: "python")
        XCTAssertEqual(tokens.first, CodeToken("# 注释", .comment))
        XCTAssertTrue(tokens.contains(CodeToken("import", .keyword)))
        XCTAssertTrue(tokens.contains(CodeToken("def", .keyword)))
        XCTAssertTrue(tokens.contains { $0.kind == .keyword && $0.text.lowercased() == "none" })
    }

    func testJSONStringsAndLiterals() {
        let tokens = CodeHighlighter.tokens("{\"ok\": true, \"n\": 12}", language: "json")
        XCTAssertTrue(tokens.contains(CodeToken("\"ok\"", .string)))
        XCTAssertTrue(tokens.contains(CodeToken("true", .keyword)))
        XCTAssertTrue(tokens.contains(CodeToken("12", .number)))
    }

    /// 没闭合的字符串不能把后面几行都染成字符串
    func testUnterminatedStringStopsAtLineEnd() {
        let code = "let a = \"oops\nlet b = 2"
        let tokens = CodeHighlighter.tokens(code, language: "swift")
        XCTAssertEqual(tokens.map(\.text).joined(), code)
        XCTAssertTrue(tokens.contains { $0.kind == .keyword && $0.text == "let" })
        XCTAssertTrue(tokens.contains { $0.kind == .number && $0.text == "2" })
    }

    func testUnknownLanguageIsPlain() {
        let tokens = CodeHighlighter.tokens("some random text 123", language: "")
        XCTAssertEqual(tokens.map(\.kind), [.plain])
    }

    func testBlockComment() {
        let tokens = CodeHighlighter.tokens("/* a\nb */\nlet x = 1", language: "swift")
        XCTAssertTrue(tokens.contains { $0.kind == .comment && $0.text.hasPrefix("/* a") })
        XCTAssertTrue(tokens.contains { $0.kind == .number })
    }
}
