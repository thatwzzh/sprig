import Foundation

/// 搜索后端。两家各有取舍：
/// - Tavily 有免费额度（1000 次/月），适合轻量使用
/// - DeepSeek 没有免费额度，但单价低约 11 倍，而且摘要长度正好是给模型读的
public enum SearchBackend: String, Codable, Sendable, CaseIterable {
    case tavily
    case deepseek

    public var title: String {
        switch self {
        case .tavily: return "Tavily"
        case .deepseek: return "DeepSeek"
        }
    }

    /// 领 Key 的地址
    public var keyURL: URL? {
        switch self {
        case .tavily: return URL(string: "https://tavily.com/")
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
        }
    }

    /// 设置页输入框的占位文字
    public var keyPlaceholder: String {
        switch self {
        case .tavily: return "Tavily API Key（tvly-…）"
        case .deepseek: return "DeepSeek API Key（sk-…）"
        }
    }

    /// 计费说明，显示在按钮 tooltip 和说明文字里
    public var quotaNote: String {
        switch self {
        case .tavily: return "Tavily 免费 1000 次/月，超出约 $0.008/次"
        case .deepseek: return "DeepSeek 按次计费，5 元/1000 次成功请求（空结果不计费）"
        }
    }
}

/// 一条搜索结果。模型看摘要，用户看标题和链接。
public struct SearchItem: Codable, Sendable, Equatable {
    public let title: String
    public let url: String
    public let summary: String

    public init(title: String, url: String, summary: String) {
        self.title = title
        self.url = url
        self.summary = summary
    }

    public var host: String? {
        URL(string: url)?.host
    }
}

/// 一次搜索的结果：`modelText` 回填给模型，`items` 用于在面板上展示来源。
public struct SearchReport: Sendable {
    public let modelText: String
    public let items: [SearchItem]

    public init(modelText: String, items: [SearchItem]) {
        self.modelText = modelText
        self.items = items
    }
}

/// 联网搜索工具。
///
/// 两个后端返回同样格式的文本，模型侧行为一致：标题、来源、摘要逐条列出。
/// 摘要截到 600 字——5 条约 3000 字，再多会把卡片上下文挤掉
/// （`ContextAssembler` 的 `toolReserve` 会先扣掉这部分）。
public enum WebSearchTool {
    public static let name = "web_search"

    public static var definition: ToolDefinition {
        ToolDefinition(
            name: name,
            description: """
            搜索互联网获取**实时**信息。只在下面这些情况调用：
            - 最近发生的事、新闻、时事
            - 当前价格（股票、金价、汇率）、天气、比分
            - 软件/库的最新版本号、发布日期、更新日志
            - 你确实不知道的冷门事实或具体数据

            **不要**为稳定的基础知识调用搜索：编程概念、设计模式、算法、
            历史常识、数学公式、语法用法——这类内容直接凭知识回答。
            搜它们只会拿到营销文和新闻稿，反而把答案质量拉低。
            一次调用传一组关键词；不同角度分多次，但总共别超过 2 次。
            """,
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "query": {
                  "type": "string",
                  "description": "搜索关键词，用提问者的语言"
                }
              },
              "required": ["query"]
            }
            """
        )
    }

    /// 执行一次搜索。
    public static func execute(argumentsJSON: String,
                               backend: SearchBackend,
                               apiKey: String,
                               session: URLSession = HTTPClient.streaming) async throws -> SearchReport {
        let query = try parseQuery(argumentsJSON)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw LLMError.server("没有配置 \(backend.title) 的搜索 API Key")
        }

        switch backend {
        case .tavily:
            return try await searchTavily(query: query, apiKey: key, session: session)
        case .deepseek:
            return try await searchDeepSeek(query: query, apiKey: key, session: session)
        }
    }

    /// 解析模型给的 arguments。模型偶尔会换字段名，这里容错几个常见写法。
    public static func parseQuery(_ argumentsJSON: String) throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decode(argumentsJSON)
        }
        let raw = (object["query"] as? String)
            ?? (object["q"] as? String)
            ?? (object["keywords"] as? String)
            ?? ""
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw LLMError.server("搜索关键词是空的")
        }
        return query
    }

    // MARK: - Tavily

    private static func searchTavily(query: String,
                                     apiKey: String,
                                     session: URLSession) async throws -> SearchReport {
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "query": query,
            "search_depth": "basic",
            // 3 条足够模型判断，5 条里常混进聚合站和新闻稿
            "max_results": 3,
            "topic": "general",
            // 不取 Tavily 的现成答案：让模型自己整合，避免措辞被二次转述
            "include_answer": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request, session: session, label: "Tavily")
        return formatTavily(payload: data, query: query)
    }

    static func formatTavily(payload: Data, query: String) -> SearchReport {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              !results.isEmpty else {
            return emptyReport(query: query)
        }

        let items = results.prefix(5).map { item -> SearchItem in
            SearchItem(title: nonEmpty(item["title"] as? String) ?? "（无标题）",
                       url: nonEmpty(item["url"] as? String) ?? "",
                       summary: truncate(item["content"] as? String) ?? "")
        }
        return report(from: Array(items), query: query)
    }

    // MARK: - DeepSeek

    private static func searchDeepSeek(query: String,
                                       apiKey: String,
                                       session: URLSession) async throws -> SearchReport {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/v1/tools/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // count 只要 5：单次价格跟条数无关，但条数越多进 prompt 的 token 越贵
        let body: [String: Any] = [
            "query": query,
            "count": 5,
            "need_content": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request, session: session, label: "DeepSeek")
        return formatDeepSeek(payload: data, query: query)
    }

    /// DeepSeek 的响应带两个质量信号：`rerank_score` 0~3（≥1.5 算高质量）、
    /// `authority` 0~4（≥3 是高权威）。优先留高质量的，一条都没有就按原顺序全留。
    static func formatDeepSeek(payload: Data, query: String) -> SearchReport {
        guard let parsed = try? JSONDecoder().decode(DeepSeekPayload.self, from: payload),
              !parsed.results.isEmpty else {
            return emptyReport(query: query)
        }

        let scored = parsed.results.map { ($0, $0.rerankScore ?? 0) }
        let strong = scored.filter { $0.1 >= 1.5 }
        let pool = Array((strong.isEmpty ? scored : strong)
            .sorted { $0.1 > $1.1 }
            .prefix(5))

        let items = pool.map { pair -> SearchItem in
            let item = pair.0
            return SearchItem(
                title: nonEmpty(item.title) ?? "（无标题）",
                url: nonEmpty(item.url) ?? "",
                // summary 是 600–800 字、留给模型读的；snippet 只有 100–200 字，作退路
                summary: truncate(item.summary) ?? truncate(item.snippet) ?? "")
        }
        return report(from: items, query: query)
    }

    private struct DeepSeekPayload: Decodable {
        struct Item: Decodable {
            let title: String?
            let url: String?
            let snippet: String?
            let summary: String?
            let rerankScore: Double?
            let authority: Int?

            enum CodingKeys: String, CodingKey {
                case title, url, snippet, summary, authority
                case rerankScore = "rerank_score"
            }
        }
        let results: [Item]
    }

    // MARK: - 公共

    /// 两个后端统一成一样的文本，模型侧不用区分来源
    static func report(from items: [SearchItem], query: String) -> SearchReport {
        guard !items.isEmpty else { return emptyReport(query: query) }

        var lines = ["搜索「\(query)」的结果："]
        for (index, item) in items.enumerated() {
            lines.append("")
            lines.append("[\(index + 1)] \(item.title)")
            if !item.url.isEmpty { lines.append("来源：\(item.url)") }
            if !item.summary.isEmpty { lines.append(item.summary) }
        }
        return SearchReport(modelText: lines.joined(separator: "\n"), items: items)
    }

    private static func emptyReport(query: String) -> SearchReport {
        SearchReport(modelText: "搜索「\(query)」没有找到结果。", items: [])
    }

    private static func send(_ request: URLRequest,
                             session: URLSession,
                             label: String) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.server("\(label) 搜索没有返回 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            throw LLMError.http(status: http.statusCode,
                                body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static func truncate(_ raw: String?, limit: Int = 600) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}
