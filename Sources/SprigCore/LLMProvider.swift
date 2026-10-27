import Foundation

/// 一个可插拔的模型提供方。UI 只依赖这个协议，加 Ollama / Gemini 都只是新增文件。
public protocol LLMProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// 本机推理的模型：上下文窗口小、对长输入更敏感，装上下文时用紧一点的预算
    var isLocal: Bool { get }
    func stream(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
}

public extension LLMProvider {
    var isLocal: Bool { false }
}

public enum LLMError: LocalizedError, Sendable {
    case badURL(String)
    case http(status: Int, body: String)
    case server(String)
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let s):
            return "地址无效：\(s)"
        case .http(let status, let body):
            return "请求失败（HTTP \(status)）：\(body.prefix(300))"
        case .server(let msg):
            return "服务端返回错误：\(msg)"
        case .decode(let raw):
            return "响应无法解析：\(raw.prefix(200))"
        }
    }
}
