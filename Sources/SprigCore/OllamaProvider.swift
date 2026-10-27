import Foundation

/// Ollama 的 /api/chat，NDJSON 流式。不引 SDK，60 行足够。
public struct OllamaProvider: LLMProvider {
    public let id = "ollama"
    public let displayName = "Ollama（本地）"

    public var baseURL: URL
    public var model: String
    public var temperature: Double

    private let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
                model: String,
                temperature: Double = 0.3) {
        self.baseURL = baseURL
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
                        for try await line in bytes.lines.prefix(5) { body += line }
                        throw LLMError.http(status: http.statusCode, body: body)
                    }

                    for try await line in bytes.lines {
                        if line.isEmpty { continue }
                        guard let data = line.data(using: .utf8) else { continue }
                        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        if let error = object["error"] as? String {
                            throw LLMError.server(error)
                        }
                        if let message = object["message"] as? [String: Any],
                           let content = message["content"] as? String,
                           !content.isEmpty {
                            continuation.yield(content)
                        }
                        if object["done"] as? Bool == true { break }
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
        let endpoint = baseURL.appendingPathComponent("api/chat")
        guard endpoint.scheme != nil else { throw LLMError.badURL(baseURL.absoluteString) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": true,
            // 关掉思维链：qwen3 系默认会先吐一大段 thinking，面板里等不起
            "think": false,
            // 让模型留在显存里，第二次唤起时首 token 更快
            "keep_alive": "30m",
            "options": [
                "temperature": temperature,
                "num_predict": 1024,
                // 默认 262144 的上下文会把 10GB 模型拖到 20GB 占用、30s/token
                "num_ctx": 8192,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

extension OllamaProvider {
    /// 拉本地模型列表，用于设置页和默认模型选择。
    public static func availableModels(baseURL: URL = URL(string: "http://127.0.0.1:11434")!) async -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = object["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["name"] as? String }
                .filter { !$0.contains("embedding") }
                .sorted()
        } catch {
            return []
        }
    }
}
