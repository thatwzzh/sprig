import Foundation

/// 一个可插拔的模型提供方。UI 只依赖这个协议，加 Ollama / Gemini 都只是新增文件。
public protocol LLMProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// 本机推理的模型：上下文窗口小、对长输入更敏感，装上下文时用紧一点的预算
    var isLocal: Bool { get }
    func stream(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
    /// 带工具的流式。不支持的 provider 走默认实现，退化成纯文本。
    func streamEvents(messages: [ChatMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<ChatEvent, Error>
}

public extension LLMProvider {
    var isLocal: Bool { false }

    /// 默认实现：忽略 tools，把文本流包成事件流。
    /// 这样 Ollama / Gemini 不用改，未接工具时行为与之前完全一致。
    func streamEvents(messages: [ChatMessage],
                      tools: [ToolDefinition]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in stream(messages: messages) {
                        continuation.yield(.text(chunk))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum LLMError: LocalizedError, Sendable {
    case badURL(String)
    case http(status: Int, body: String)
    case server(String)
    case decode(String)
    /// 网络层问题（断网、超时、连不上主机）
    case network(String)
    /// 请求成功但一个字都没吐出来
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .badURL(let value):
            return "地址无效：\(value)"
        case .http(let status, let body):
            return Self.httpMessage(status: status, body: body)
        case .server(let message):
            return "服务端返回错误：\(message)"
        case .decode(let raw):
            return "响应无法解析：\(raw.prefix(200))"
        case .network(let message):
            return message
        case .emptyResponse:
            return "模型没有返回任何内容。"
        }
    }

    /// HTTP 状态码翻成「按这个改」的话，而不是甩一串英文原文
    private static func httpMessage(status: Int, body: String) -> String {
        switch status {
        case 400:
            return "请求被拒绝（HTTP 400）：多半是模型名不对，或该模型不支持这次请求带的参数。"
        case 401, 403:
            return "鉴权失败（HTTP \(status)）：API Key 无效，或这条 Key 没有该模型的权限。"
        case 404:
            return "接口或模型不存在（HTTP 404）。Gemini 常见于模型已下线（去 AI Studio 看当前模型名）；"
                + "其他服务检查 Base URL 是否该以 /v1 结尾。"
        case 429:
            return "被限流了（HTTP 429）：免费层有每分钟次数限制，等一分钟再问。"
        case 500...599:
            return "对方服务器出错（HTTP \(status)）：不是本机的问题，稍后重试。"
        default:
            let tail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "请求失败（HTTP \(status)）\(tail.isEmpty ? "" : "：\(tail.prefix(160))")"
        }
    }

    /// 值得原样重试一次的故障：TLS 握手、连接中断、超时。
    /// 这类多半是链路瞬抖，重连通常就过了，换模型没有意义（同一个域名）。
    public var isTransient: Bool {
        guard case .network(let message) = self else { return false }
        return message.contains("TLS") || message.contains("连接不上")
            || message.contains("超时") || message.contains("连接中途")
    }

    /// 把 URLSession 的错误翻译成能照着做的中文。
    /// 直接透 `localizedDescription` 会得到 "The Internet connection appears to be offline."，
    /// 对用户没有任何指导意义。
    public static func wrapping(_ error: Error) -> LLMError {
        if let llm = error as? LLMError { return llm }

        guard let urlError = error as? URLError else {
            return .server(error.localizedDescription)
        }
        switch urlError.code {
        case .notConnectedToInternet:
            return .network("设备没有联网，检查 Wi-Fi 或网线。")
        case .timedOut:
            return .network("请求超时：模型可能太慢，或网络不稳定。")
        case .cannotFindHost, .dnsLookupFailed:
            return .network("域名解析失败：Base URL 里的主机名可能写错了。")
        case .cannotConnectToHost, .networkConnectionLost:
            return .network("连不上服务器：检查 Base URL 和端口；本地模型先确认已启动。")
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return .network("TLS 握手失败：该域名可能被网络拦截（代理规则、防火墙），"
                + "也可能是证书问题。先确认这个域名在当前网络下能访问。")
        case .cancelled:
            return .network("请求已取消。")
        default:
            return .network("网络错误：\(urlError.localizedDescription)")
        }
    }
}
