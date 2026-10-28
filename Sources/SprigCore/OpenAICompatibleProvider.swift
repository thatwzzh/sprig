import Foundation

/// OpenAI 兼容的 `/v1/chat/completions`，SSE 流式。
/// 一套实现覆盖 OpenAI、DeepSeek、Moonshot、Groq、OpenRouter、LM Studio、vLLM 等。
public struct OpenAICompatibleProvider: LLMProvider {
    public let id: String
    public let displayName: String
    public var baseURL: URL
    public var apiKey: String
    public var model: String
    public var temperature: Double
    /// 关掉推理模型的思考链。只对 OpenRouter 生效——别的网关不认这个字段，
    /// 乱发可能直接 400。
    public var disableThinking: Bool

    private let session: URLSession

    public init(id: String = "openai",
                displayName: String = "OpenAI 兼容",
                baseURL: URL,
                apiKey: String,
                model: String,
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
                        // SSE：忽略空行和 event: 行，只吃 data:
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count)
                            .trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        if let error = object["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            throw LLMError.server(message)
                        }
                        guard let choices = object["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any] else {
                            continue
                        }
                        // 推理模型会先吐 reasoning_content，面板里不展示思考过程
                        if let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(content)
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

    /// 带工具的一轮请求。
    /// 流式下 `tool_calls` 是分片到达的（id/name 通常只在第一片，arguments 逐段追加），
    /// 所以按 `index` 累积，流结束后一次性吐出完整的调用。
    public func streamEvents(messages: [ChatMessage],
                             tools: [ToolDefinition]) -> AsyncThrowingStream<ChatEvent, Error> {
        guard !tools.isEmpty else {
            // 没工具就是普通对话，别多走一遍解析
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await chunk in stream(messages: messages) {
                            continuation.yield(.text(chunk))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: LLMError.wrapping(error))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        return AsyncThrowingStream { continuation in
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

                    var partials: [Int: PartialToolCall] = [:]

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count)
                            .trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        if let error = object["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            throw LLMError.server(message)
                        }
                        guard let choices = object["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any] else {
                            continue
                        }

                        if let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(.text(content))
                        }

                        if let rawCalls = delta["tool_calls"] as? [[String: Any]] {
                            for raw in rawCalls {
                                let index = raw["index"] as? Int ?? 0
                                var partial = partials[index] ?? PartialToolCall()
                                if let id = raw["id"] as? String, !id.isEmpty { partial.id = id }
                                if let fn = raw["function"] as? [String: Any] {
                                    if let name = fn["name"] as? String, !name.isEmpty {
                                        partial.name = name
                                    }
                                    if let args = fn["arguments"] as? String {
                                        partial.arguments += args
                                    }
                                }
                                partials[index] = partial
                            }
                        }
                    }

                    if !partials.isEmpty {
                        let calls = partials
                            .sorted { $0.key < $1.key }
                            .compactMap { _, partial -> ToolCall? in
                                guard !partial.name.isEmpty else { return nil }
                                return ToolCall(id: partial.id.isEmpty ? UUID().uuidString : partial.id,
                                                name: partial.name,
                                                arguments: partial.arguments)
                            }
                        if !calls.isEmpty {
                            continuation.yield(.toolCalls(calls))
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

    private func makeRequest(messages: [ChatMessage],
                             tools: [ToolDefinition] = []) throws -> URLRequest {
        var request = URLRequest(url: chatEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map(encodeMessage),
            "stream": true,
            "temperature": temperature,
        ]

        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                let parameters = (try? JSONSerialization.jsonObject(
                    with: Data(tool.parametersJSON.utf8))) as? [String: Any]
                    ?? ["type": "object", "properties": [String: Any]()]
                return [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": parameters,
                    ],
                ]
            }
            body["tool_choice"] = "auto"
        }

        // OpenRouter 认这个写法；别的网关不认，发了可能 400，所以按 baseURL 判断
        if disableThinking, baseURL.host?.contains("openrouter") == true {
            body["reasoning"] = ["effort": "none"]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// role 是 tool 的消息要带 `tool_call_id`，assistant 的调用请求要带 `tool_calls`
    private func encodeMessage(_ message: ChatMessage) -> [String: Any] {
        var dict: [String: Any] = [
            "role": message.role.rawValue,
            "content": message.content,
        ]
        if let calls = message.toolCalls, !calls.isEmpty {
            dict["tool_calls"] = calls.map { call -> [String: Any] in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.arguments,
                    ],
                ]
            }
        }
        if let callID = message.toolCallID {
            dict["tool_call_id"] = callID
        }
        return dict
    }

    private struct PartialToolCall: Sendable {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    /// 用户可能填 `https://api.deepseek.com`、`https://x/v1`，甚至完整 endpoint。
    /// 三种都归一化到 `/v1/chat/completions`。
    private var chatEndpoint: URL {
        var path = baseURL.path
        while path.hasSuffix("/") { path.removeLast() }

        if path.hasSuffix("/chat/completions") { return baseURL }

        var url = baseURL
        if !path.hasSuffix("/v1") {
            url.appendPathComponent("v1")
        }
        return url.appendingPathComponent("chat/completions")
    }
}

/// 一条可选的模型。`isFree` 只有 OpenRouter 这类带 pricing 字段的网关能判断出来。
public struct ModelOption: Sendable, Equatable {
    public let id: String
    public let isFree: Bool

    public init(id: String, isFree: Bool) {
        self.id = id
        self.isFree = isFree
    }
}

public extension OpenAICompatibleProvider {
    /// 拉模型列表并标出免费项。OpenRouter 的 `/v1/models` 带 pricing，
    /// prompt 和 completion 都为 0 就是免费；OpenAI 官方接口没有 pricing，全是 false。
    static func modelOptions(baseURL: URL, apiKey: String) async -> [ModelOption] {
        var path = baseURL.path
        while path.hasSuffix("/") { path.removeLast() }
        var url = baseURL
        if !path.hasSuffix("/v1") { url.appendPathComponent("v1") }
        url.appendPathComponent("models")

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, _) = try await HTTPClient.streaming.data(for: request)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = object["data"] as? [[String: Any]] else { return [] }
            return items.compactMap { item -> ModelOption? in
                guard let id = item["id"] as? String else { return nil }
                let pricing = item["pricing"] as? [String: Any]
                let free = isZero(pricing?["prompt"]) && isZero(pricing?["completion"])
                return ModelOption(id: id, isFree: free)
            }
            .sorted { $0.id < $1.id }
        } catch {
            return []
        }
    }

    /// pricing 里的价格是字符串（"0" / "0.000001"），也见过数字类型
    private static func isZero(_ raw: Any?) -> Bool {
        switch raw {
        case let string as String: return Double(string) == 0
        case let number as NSNumber: return number.doubleValue == 0
        default: return false
        }
    }

    /// 拉模型列表（GET /v1/models），用于设置页的「拉取」按钮。
    static func availableModels(baseURL: URL, apiKey: String) async -> [String] {
        var path = baseURL.path
        while path.hasSuffix("/") { path.removeLast() }
        var url = baseURL
        if !path.hasSuffix("/v1") { url.appendPathComponent("v1") }
        url.appendPathComponent("models")

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = object["data"] as? [[String: Any]] else { return [] }
            return items.compactMap { $0["id"] as? String }.sorted()
        } catch {
            return []
        }
    }
}
