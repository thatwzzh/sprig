import Foundation

/// 联网搜索工具。
///
/// 用 Tavily（1000 次/月免费）：它直接返回每条结果的正文摘要，能原样塞进 prompt，
/// 不像通用搜索 API 只给链接和一句话描述、还要自己抓网页。
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
                               apiKey: String,
                               session: URLSession = .shared) async throws -> String {
        let query = try parseQuery(argumentsJSON)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw LLMError.server("没有配置搜索 API Key")
        }

        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "query": query,
            "search_depth": "basic",
            "max_results": 5,
            // 不取 Tavily 的现成答案：让模型自己整合，避免它的措辞被二次转述
            "include_answer": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.server("搜索没有返回 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            throw LLMError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        return format(payload: data, query: query)
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

    /// 拼成模型好读的文本。每条摘要截到 600 字——5 条约 3000 字，
    /// 再多会把上下文预算吃掉大半，反而挤掉卡片本身的内容。
    static func format(payload: Data, query: String) -> String {
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
            var content = (item["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if content.count > 600 {
                content = String(content.prefix(600)) + "…"
            }

            lines.append("")
            lines.append("[\(index + 1)] \(title)")
            if !url.isEmpty { lines.append("来源：\(url)") }
            if !content.isEmpty { lines.append(content) }
        }
        return lines.joined(separator: "\n")
    }
}
