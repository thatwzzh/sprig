import Foundation

/// 一次工具调用请求。
/// `arguments` 是模型吐出来的 JSON 原文——流式下它是分片拼起来的，可能不合法，交给执行方解析。
public struct ToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// 交给模型的工具描述。`parametersJSON` 是 JSON Schema 原文，直接拼进请求体，
/// 不走 Codable 是为了不必为每种 provider 的 schema 方言再包一层。
public struct ToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

/// 流式事件：文本增量；或一轮结束时要求调工具。
public enum ChatEvent: Sendable {
    case text(String)
    case toolCalls([ToolCall])
}
