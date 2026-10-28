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

/// 联网搜索工具。
///
/// 两个后端返回同样格式的文本，模型侧行为一致：标题、来源、摘要逐条列出。
/// 摘要截到 600 字——5 条约 3000 字，再多会把卡片上下文挤掉
/// （`ContextAssembler` 的预算不含搜索结果）。
public enum WebSearchTool {
    public static let name = "web_search"

    public static var definition: ToolDefinition {
        ToolDefinition(
            name: name,
            description: """
            搜索互联网获取实时信息。问题涉及近期新闻、最新版本号或价格、\
            或者你不确定的事实，先调用它再回答，不要凭记忆编造。
            一次调用传一组关键词；需要查不同角度时分多次调用。
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

    /// 执行一次搜索，返回给模型看的纯文本。
    public static func execute(argumentsJSON: String,
                               backend: SearchBackend,
                               apiKey: String,
                               session: URLSession = .shared) async throws -> String {
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
                                     session: URLSession) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "query": query,
            "search_depth": "basic",
            "max_results": 5,
            // 不取 Tavily 的现成答案：让模型自己整合，避免措辞被二次转述
            "include_answer": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request, session: session, label: "Tavily")
        return formatTavily(payload: data, query: query)
    }

    /// 拼成模型好读的文本。每条摘要截到 600 字。
    static func formatTavily(payload: Data, query: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              !results.isEmpty else {
            return "搜索「\(query)」没有找到结果。"
        }

        var lines = ["搜索「\(query)」的结果："]
        for (index, item) in results.prefix(5).enumerated() {
            let title = (item["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "（无标题）"
            let url = item["url"] as? String ?? ""
            let content = truncate(item["content"] as? String)

            lines.append("")
            lines.append("[\(index + 1)] \(title)")
            if !url.isEmpty { lines.append("来源：\(url)") }
            if let content { lines.append(content) }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - DeepSeek

    private static func searchDeepSeek(query: String,
                                       apiKey: String,
                                       session: URLSession) async throws -> String {
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
    static func formatDeepSeek(payload: Data, query: String) -> String {
        guard let parsed = try? JSONDecoder().decode(DeepSeekPayload.self, from: payload),
              !parsed.results.isEmpty else {
            return "搜索「\(query)」没有找到结果。"
        }

        let scored = parsed.results.map { ($0, $0.rerankScore ?? 0) }
        let strong = scored.filter { $0.1 >= 1.5 }
        let pool = Array((strong.isEmpty ? scored : strong)
            .sorted { $0.1 > $1.1 }
            .prefix(5))

        var lines = ["搜索「\(query)」的结果："]
        for (index, pair) in pool.enumerated() {
            let item = pair.0
            let title = nonEmpty(item.title) ?? "（无标题）"
            // summary 是 600–800 字、留给模型读的；snippet 只有 100–200 字，作退路
            let body = truncate(item.summary) ?? truncate(item.snippet) ?? ""

            lines.append("")
            lines.append("[\(index + 1)] \(title)")
            if let url = nonEmpty(item.url) { lines.append("来源：\(url)") }
            if !body.isEmpty { lines.append(body) }
        }
        return lines.joined(separator: "\n")
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
