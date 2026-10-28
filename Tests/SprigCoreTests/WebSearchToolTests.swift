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
        let report = WebSearchTool.formatTavily(payload: payload, query: "测试")

        XCTAssertTrue(report.modelText.contains("搜索「测试」的结果"))
        XCTAssertTrue(report.modelText.contains("[1] 标题A"))
        XCTAssertTrue(report.modelText.contains("来源：https://a.com"))
        XCTAssertTrue(report.modelText.contains("[2] 标题B"))
    }

    /// 单条摘要要截断，否则 5 条就能把上下文预算吃光
    func testFormatTruncatesLongContent() {
        let long = String(repeating: "字", count: 2_000)
        let payload = try! JSONSerialization.data(withJSONObject: [
            "results": [["title": "T", "url": "https://x.com", "content": long]],
        ])
        let report = WebSearchTool.formatTavily(payload: payload, query: "q")
        XCTAssertTrue(report.modelText.contains("…"), "超长摘要应被截断")
        XCTAssertLessThan(report.modelText.count, 900)
    }

    func testFormatHandlesEmptyResults() {
        let payload = #"{"results":[]}"#.data(using: .utf8)!
        XCTAssertTrue(WebSearchTool.formatTavily(payload: payload, query: "q").modelText.contains("没有找到结果"))
    }

    func testFormatHandlesGarbagePayload() {
        let payload = "not json".data(using: .utf8)!
        XCTAssertTrue(WebSearchTool.formatTavily(payload: payload, query: "q").modelText.contains("没有找到结果"))
    }

    // MARK: - DeepSeek 后端

    func testDeepSeekPrefersSummaryOverSnippet() {
        let payload = """
        {"results":[
          {"title":"标题A","url":"https://a.com","summary":"这是给模型读的长摘要","snippet":"短摘要","rerank_score":2.1,"authority":3}
        ]}
        """.data(using: .utf8)!
        let report = WebSearchTool.formatDeepSeek(payload: payload, query: "测试")

        XCTAssertTrue(report.modelText.contains("[1] 标题A"))
        XCTAssertTrue(report.modelText.contains("这是给模型读的长摘要"))
        XCTAssertFalse(report.modelText.contains("短摘要"), "有 summary 就不该退回 snippet")
    }

    func testDeepSeekFallsBackToSnippet() {
        let payload = """
        {"results":[
          {"title":"标题B","url":"https://b.com","snippet":"只有短摘要","rerank_score":2.0}
        ]}
        """.data(using: .utf8)!
        let report = WebSearchTool.formatDeepSeek(payload: payload, query: "q")
        XCTAssertTrue(report.modelText.contains("只有短摘要"))
    }

    /// rerank_score < 1.5 的低质量结果应该被剔掉
    func testDeepSeekDropsLowScoreResults() {
        let payload = """
        {"results":[
          {"title":"高质量","url":"https://good.com","summary":"好","rerank_score":2.4},
          {"title":"低质量","url":"https://bad.com","summary":"差","rerank_score":0.8}
        ]}
        """.data(using: .utf8)!
        let report = WebSearchTool.formatDeepSeek(payload: payload, query: "q")

        XCTAssertTrue(report.modelText.contains("高质量"))
        XCTAssertFalse(report.modelText.contains("低质量"))
    }

    /// 全都低于 1.5 时不能返回空，要按分数排
    func testDeepSeekKeepsAllWhenNonePassThreshold() {
        let payload = """
        {"results":[
          {"title":"较弱","url":"https://a.com","summary":"a","rerank_score":0.9},
          {"title":"最弱","url":"https://b.com","summary":"b","rerank_score":0.3}
        ]}
        """.data(using: .utf8)!
        let report = WebSearchTool.formatDeepSeek(payload: payload, query: "q")

        XCTAssertTrue(report.modelText.contains("较弱"))
        XCTAssertTrue(report.modelText.contains("最弱"))
        // 分高的排前面
        let first = report.modelText.range(of: "较弱")!.lowerBound
        let second = report.modelText.range(of: "最弱")!.lowerBound
        XCTAssertLessThan(first, second)
    }

    func testDeepSeekHandlesEmptyResults() {
        let payload = #"{"results":[]}"#.data(using: .utf8)!
        XCTAssertTrue(WebSearchTool.formatDeepSeek(payload: payload, query: "q").modelText.contains("没有找到结果"))
    }

    // MARK: - 后端元数据

    func testSearchBackendMetadata() {
        for backend in SearchBackend.allCases {
            XCTAssertFalse(backend.title.isEmpty)
            XCTAssertNotNil(backend.keyURL, "\(backend.title) 应该有领 Key 的地址")
            XCTAssertFalse(backend.keyPlaceholder.isEmpty)
            XCTAssertFalse(backend.quotaNote.isEmpty)
        }
        XCTAssertEqual(SearchBackend.tavily.keyURL?.host, "tavily.com")
        XCTAssertEqual(SearchBackend.deepseek.keyURL?.host, "platform.deepseek.com")
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
