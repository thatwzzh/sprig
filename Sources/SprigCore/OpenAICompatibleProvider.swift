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

    private let session: URLSession

    public init(id: String = "openai",
                displayName: String = "OpenAI 兼容",
                baseURL: URL,
                apiKey: String,
                model: String,
                temperature: Double = 0.3) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
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
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(messages: [ChatMessage]) throws -> URLRequest {
        var request = URLRequest(url: chatEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": true,
            "temperature": temperature,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
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

public extension OpenAICompatibleProvider {
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
