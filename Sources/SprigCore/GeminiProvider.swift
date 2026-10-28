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
        // 纯文本路径：丢掉工具事件，行为和以前一致
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in streamEvents(messages: messages, tools: []) {
                        if case .text(let chunk) = event { continuation.yield(chunk) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LLMError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func streamEvents(messages: [ChatMessage],
                             tools: [ToolDefinition]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(messages: messages, tools: tools)
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.server("没有收到 HTTP 响应")
                    }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines.prefix(8) { body += line }
                        throw LLMError.http(status: http.statusCode, body: body)
                    }

                    var pendingCalls: [ToolCall] = []
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
                                continuation.yield(.text(text))
                            }
                            // Gemini 把工具调用放在 parts 里的 functionCall，
                            // 没有 call id，自己生成一个用于回填结果
                            if let call = part["functionCall"] as? [String: Any],
                               let name = call["name"] as? String, !name.isEmpty {
                                let args = call["args"] as? [String: Any] ?? [:]
                                let json = (try? JSONSerialization.data(withJSONObject: args))
                                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                pendingCalls.append(ToolCall(id: UUID().uuidString,
                                                             name: name,
                                                             arguments: json))
                            }
                        }
                    }
                    if !pendingCalls.isEmpty {
                        continuation.yield(.toolCalls(pendingCalls))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LLMError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(messages: [ChatMessage],
                             tools: [ToolDefinition] = []) throws -> URLRequest {
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
        // Gemini 的 functionResponse 只认工具名，这里记下 id → name 好回填
        var callNames: [String: String] = [:]
        for message in messages {
            switch message.role {
            case .system:
                systemText = (systemText.map { $0 + "\n\n" } ?? "") + message.content
            case .user:
                contents.append(["role": "user", "parts": [["text": message.content]]])
            case .assistant:
                if let calls = message.toolCalls, !calls.isEmpty {
                    var parts: [[String: Any]] = []
                    for call in calls {
                        callNames[call.id] = call.name
                        let args = (try? JSONSerialization.jsonObject(
                            with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
                        parts.append(["functionCall": ["name": call.name, "args": args]])
                    }
                    contents.append(["role": "model", "parts": parts])
                } else if !message.content.isEmpty {
                    contents.append(["role": "model", "parts": [["text": message.content]]])
                }
            case .tool:
                // Gemini 用 functionResponse 回传结果，role 是 user；
                // 它没有 call id，只能靠工具名对应
                let name = message.toolCallID.flatMap { callNames[$0] } ?? "tool"
                contents.append(["role": "user", "parts": [[
                    "functionResponse": ["name": name,
                                         "response": ["result": message.content]],
                ]]])
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
        if !tools.isEmpty {
            body["tools"] = [["functionDeclarations": tools.map(declaration(for:))]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 把我们的 ToolDefinition 翻成 Gemini 的 functionDeclarations 条目。
    private func declaration(for tool: ToolDefinition) -> [String: Any] {
        var parameters: [String: Any] = [:]
        if let data = tool.parametersJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parameters = uppercaseSchemaTypes(parsed)
        }
        return ["name": tool.name,
                "description": tool.description,
                "parameters": parameters]
    }

    /// Gemini 的 schema 要求类型名大写（OBJECT / STRING / ARRAY），
    /// 我们存的是标准 JSON Schema 的小写写法，递归改一遍。
    private func uppercaseSchemaTypes(_ node: [String: Any]) -> [String: Any] {
        var out = node
        if let type = node["type"] as? String { out["type"] = type.uppercased() }
        if let properties = node["properties"] as? [String: Any] {
            out["properties"] = properties.mapValues { value -> Any in
                (value as? [String: Any]).map(uppercaseSchemaTypes) ?? value
            }
        }
        if let items = node["items"] as? [String: Any] {
            out["items"] = uppercaseSchemaTypes(items)
        }
        return out
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
