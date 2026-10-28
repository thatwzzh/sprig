import Foundation

/// 一个模型的探测结果。
public struct ProbeResult: Sendable {
    public enum Failure: Sendable, Equatable {
        case auth               // 401/403：Key 没权限
        case notFound           // 404：模型不存在或已下架
        case rateLimited        // 429：限流，不是模型的问题
        case badRequest(String) // 400：参数被拒，通常是不支持某些字段
        case server(Int)        // 5xx：对方故障
        case timeout
        case network(String)
        case empty              // 200 但没吐内容
        case unsupported        // 该协议不支持这种探测

        public var label: String {
            switch self {
            case .auth: return "Key 无权限"
            case .notFound: return "模型不存在"
            case .rateLimited: return "限流"
            case .badRequest(let detail): return "请求被拒：\(detail)"
            case .server(let code): return "服务端 \(code)"
            case .timeout: return "超时"
            case .network(let detail): return detail
            case .empty: return "返回空"
            case .unsupported: return "跳过"
            }
        }
    }

    public let model: String
    public let ok: Bool
    public let failure: Failure?

    public init(model: String, ok: Bool, failure: Failure? = nil) {
        self.model = model
        self.ok = ok
        self.failure = failure
    }

    public var summary: String {
        ok ? "可用" : (failure?.label ?? "未知原因")
    }

    /// 限流说明是额度问题，模型本身是好的——统计"不可用"时不该算进去
    public var isQuotaIssue: Bool {
        if case .rateLimited = failure { return true }
        return false
    }
}

/// 探测模型是否真的能调通。
///
/// 发一条最小的对话请求（`max_tokens: 1`，非流式），只看有没有正常响应。
/// 免费清单里混着下架、限流、无权限的模型，拉回来不测一遍，用户第一次提问才会发现。
public enum ModelProbe {
    public static func probe(models: [String],
                             config: ProviderConfig,
                             concurrency: Int = 4,
                             session: URLSession = HTTPClient.streaming) async -> [ProbeResult] {
        guard !models.isEmpty else { return [] }

        // 目前只有 OpenAI 兼容能这样探（Gemini 的接口形状不同，单独处理不划算）
        guard config.kind == .openAICompatible else {
            return models.map { ProbeResult(model: $0, ok: false, failure: .unsupported) }
        }

        return await withTaskGroup(of: ProbeResult.self) { group in
            var next = 0
            var results: [ProbeResult] = []
            let limit = min(concurrency, models.count)

            func submit(_ model: String) {
                group.addTask {
                    await probeOne(model: model, config: config, session: session)
                }
            }

            for _ in 0..<limit {
                submit(models[next])
                next += 1
            }

            for await result in group {
                results.append(result)
                if next < models.count {
                    submit(models[next])
                    next += 1
                }
            }
            // 按原顺序返回，方便对照清单
            return models.compactMap { model in results.first { $0.model == model } }
        }
    }

    private static func probeOne(model: String,
                                 config: ProviderConfig,
                                 session: URLSession) async -> ProbeResult {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard var url = URL(string: base) else {
            return ProbeResult(model: model, ok: false, failure: .network("Base URL 无效"))
        }
        if !url.path.hasSuffix("/v1") { url.appendPathComponent("v1") }
        url.appendPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1,
            "stream": false,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return ProbeResult(model: model, ok: false, failure: .badRequest("请求体构造失败"))
        }
        request.httpBody = payload

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ProbeResult(model: model, ok: false, failure: .network("没有 HTTP 响应"))
            }

            switch http.statusCode {
            case 200:
                // 只要有 choices 就算通，不要求内容非空（max_tokens=1 可能只吐一个字符）
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let choices = object?["choices"] as? [[String: Any]]
                if let choices, !choices.isEmpty {
                    return ProbeResult(model: model, ok: true)
                }
                return ProbeResult(model: model, ok: false, failure: .empty)
            case 401, 403:
                return ProbeResult(model: model, ok: false, failure: .auth)
            case 404:
                return ProbeResult(model: model, ok: false, failure: .notFound)
            case 429:
                return ProbeResult(model: model, ok: false, failure: .rateLimited)
            case 400:
                let text = extractMessage(from: data)
                return ProbeResult(model: model, ok: false, failure: .badRequest(text))
            case 500...599:
                return ProbeResult(model: model, ok: false, failure: .server(http.statusCode))
            default:
                return ProbeResult(model: model, ok: false,
                                   failure: .badRequest("HTTP \(http.statusCode)"))
            }
        } catch {
            if let urlError = error as? URLError {
                if urlError.code == .timedOut {
                    return ProbeResult(model: model, ok: false, failure: .timeout)
                }
                return ProbeResult(model: model, ok: false,
                                   failure: .network(urlError.localizedDescription))
            }
            return ProbeResult(model: model, ok: false,
                               failure: .network(error.localizedDescription))
        }
    }

    /// 从错误响应里挖出可读的原因（OpenRouter 放在 error.message）
    private static func extractMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.prefix(80).description ?? "无响应体"
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return String(message.prefix(100))
        }
        if let message = object["message"] as? String {
            return String(message.prefix(100))
        }
        return String(data: data, encoding: .utf8)?.prefix(80).description ?? "无响应体"
    }
}
