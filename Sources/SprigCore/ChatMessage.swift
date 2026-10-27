import Foundation

public struct ChatMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant
        /// 工具执行结果，回填给模型
        case tool
    }

    public var role: Role
    public var content: String
    /// assistant 要求模型调用的工具（可能一次调多个）
    public var toolCalls: [ToolCall]?
    /// role == .tool 时，这条结果对应哪个调用
    public var toolCallID: String?

    public init(role: Role,
                content: String,
                toolCalls: [ToolCall]? = nil,
                toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    public static func system(_ text: String) -> ChatMessage { .init(role: .system, content: text) }
    public static func user(_ text: String) -> ChatMessage { .init(role: .user, content: text) }
    public static func assistant(_ text: String) -> ChatMessage { .init(role: .assistant, content: text) }
    /// 模型要求调工具的那条消息
    public static func assistantToolCalls(_ calls: [ToolCall]) -> ChatMessage {
        .init(role: .assistant, content: "", toolCalls: calls)
    }
    /// 工具执行完的结果
    public static func toolResult(_ text: String, for callID: String) -> ChatMessage {
        .init(role: .tool, content: text, toolCallID: callID)
    }
}
