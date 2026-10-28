import Foundation

/// Google Gemini 原生接口：`v1beta/models/{model}:streamGenerateContent?alt=sse`。
///
/// 不用官方那层 OpenAI 兼容网关：它在 system 指令、候选元数据上做了改写，
/// 原生接口的报错信息（配额、key 无效、地区限制）也更容易排。
public struct GeminiProvider: LLMProvider {
    public let id: String
    public let displayName: String
    public var baseURL: URL
    public var apiKey: String
    public var model: String
    public var temperature: Double
    /// 关掉思考链。只对 flash 系加：pro 的 thinkingBudget 最少 128，传 0 会 400。
    public var disableThinking: Bool

    private let session: URLSession

    public init(id: String = "gemini",
                displayName: String = "Google Gemini",
                baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!,
                apiKey: String,
                model: String = "gemini-2.5-flash",
                temperature: Double = 0.3,
                disableThinking: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.disableThinking = disableThinking
        // 复用全局 session：每次新建会重做 TLS 握手，首字延迟明显变长
        self.session = HTTPClient.streaming
    }

    public func stream(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(messages: messages)
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.server("没有收到 HTTP 响应")
                    }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines.prefix(8) { body += line }
                        throw LLMError.http(status: http.statusCode, body: body)
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count)
                            .trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty || payload == "[DONE]" { continue }

                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        if let error = object["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            throw LLMError.server(message)
                        }
                        // 内容被安全策略拦掉时没有 candidates，只有 promptFeedback
                        if let feedback = object["promptFeedback"] as? [String: Any],
                           let reason = feedback["blockReason"] as? String,
                           object["candidates"] == nil {
                            throw LLMError.server("内容被安全策略拦截（\(reason)）")
                        }
                        guard let candidates = object["candidates"] as? [[String: Any]],
                              let content = candidates.first?["content"] as? [String: Any],
                              let parts = content["parts"] as? [[String: Any]] else {
                            continue
                        }
                        for part in parts {
                            if let text = part["text"] as? String, !text.isEmpty {
                                continuation.yield(text)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LLMError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(messages: [ChatMessage]) throws -> URLRequest {
        guard let url = endpoint else { throw LLMError.badURL(baseURL.absoluteString) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Gemini 用 header 传 key：query 里带 key 容易进日志
        request.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                         forHTTPHeaderField: "x-goog-api-key")

        // Gemini 的 contents 只有 user / model 两种角色，system 走 systemInstruction
        var systemText: String?
        var contents: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .system:
                systemText = (systemText.map { $0 + "\n\n" } ?? "") + message.content
            case .user:
                contents.append(["role": "user", "parts": [["text": message.content]]])
            case .assistant:
                contents.append(["role": "model", "parts": [["text": message.content]]])
            case .tool:
                // Gemini 这一版没接工具调用；真收到工具结果就当用户补充的参考资料
                contents.append(["role": "user", "parts": [["text": message.content]]])
            }
        }

        var generationConfig: [String: Any] = [
            "temperature": temperature,
            "maxOutputTokens": 2048,
        ]
        // 知识问答要的是快和直接，默认不思考。pro 系不支持 0，只对 flash 加。
        if disableThinking, model.lowercased().contains("flash") {
            generationConfig["thinkingConfig"] = ["thinkingBudget": 0]
        }

        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": generationConfig,
        ]
        if let systemText, !systemText.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemText]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private var endpoint: URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var path = (components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("v1beta") { path.removeLast("v1beta".count) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let modelName = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
        let prefix = path.isEmpty ? "" : "/" + path
        components?.path = "\(prefix)/v1beta/models/\(modelName):streamGenerateContent"
        components?.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        return components?.url
    }
}

public extension GeminiProvider {
    /// 拉可用模型（GET v1beta/models），用于设置页的「拉取」按钮。
    static func availableModels(baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!,
                                apiKey: String) async -> [String] {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/v1beta/models"
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                         forHTTPHeaderField: "x-goog-api-key")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = object["models"] as? [[String: Any]] else { return [] }
            return items.compactMap { item -> String? in
                guard let name = item["name"] as? String else { return nil }
                let methods = item["supportedGenerationMethods"] as? [String] ?? []
                guard methods.contains("generateContent") else { return nil }
                return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            }
        } catch {
            return []
        }
    }
}
