import XCTest
@testable import SprigCore

final class WebSearchToolTests: XCTestCase {
    // MARK: - arguments 解析

    func testParseQueryFromStandardArguments() throws {
        XCTAssertEqual(try WebSearchTool.parseQuery(#"{"query":"今天上海天气"}"#), "今天上海天气")
    }

    /// 模型偶尔会换字段名，容错几个常见写法
    func testParseQueryFromAlternateKeys() throws {
        XCTAssertEqual(try WebSearchTool.parseQuery(#"{"q":"swift 6"}"#), "swift 6")
        XCTAssertEqual(try WebSearchTool.parseQuery(#"{"keywords":"RAG"}"#), "RAG")
    }

    func testParseQueryTrimsWhitespace() throws {
        XCTAssertEqual(try WebSearchTool.parseQuery(#"{"query":"  hello  "}"#), "hello")
    }

    func testParseQueryThrowsOnBlankQuery() {
        XCTAssertThrowsError(try WebSearchTool.parseQuery(#"{"query":"   "}"#))
    }

    func testParseQueryThrowsOnInvalidJSON() {
        XCTAssertThrowsError(try WebSearchTool.parseQuery("这不是 JSON"))
    }

    // MARK: - 结果拼装

    func testFormatBuildsReadableText() {
        let payload = """
        {"results":[
          {"title":"标题A","url":"https://a.com","content":"摘要 A"},
          {"title":"标题B","url":"https://b.com","content":"摘要 B"}
        ]}
        """.data(using: .utf8)!
        let text = WebSearchTool.format(payload: payload, query: "测试")

        XCTAssertTrue(text.contains("搜索「测试」的结果"))
        XCTAssertTrue(text.contains("[1] 标题A"))
        XCTAssertTrue(text.contains("来源：https://a.com"))
        XCTAssertTrue(text.contains("[2] 标题B"))
    }

    /// 单条摘要要截断，否则 5 条就能把上下文预算吃光
    func testFormatTruncatesLongContent() {
        let long = String(repeating: "字", count: 2_000)
        let payload = try! JSONSerialization.data(withJSONObject: [
            "results": [["title": "T", "url": "https://x.com", "content": long]],
        ])
        let text = WebSearchTool.format(payload: payload, query: "q")
        XCTAssertTrue(text.contains("…"), "超长摘要应被截断")
        XCTAssertLessThan(text.count, 900)
    }

    func testFormatHandlesEmptyResults() {
        let payload = #"{"results":[]}"#.data(using: .utf8)!
        XCTAssertTrue(WebSearchTool.format(payload: payload, query: "q").contains("没有找到结果"))
    }

    func testFormatHandlesGarbagePayload() {
        let payload = "not json".data(using: .utf8)!
        XCTAssertTrue(WebSearchTool.format(payload: payload, query: "q").contains("没有找到结果"))
    }

    // MARK: - 工具定义

    func testToolDefinitionShape() throws {
        let def = WebSearchTool.definition
        XCTAssertEqual(def.name, "web_search")
        XCTAssertFalse(def.description.isEmpty)

        // parametersJSON 必须是合法 JSON Schema，否则拼进请求体会被服务端拒绝
        let data = def.parametersJSON.data(using: .utf8)!
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "object")
        let properties = object?["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["query"])
        XCTAssertEqual(object?["required"] as? [String], ["query"])
    }
}
