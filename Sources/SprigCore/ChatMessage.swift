import Foundation

public struct ChatMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ text: String) -> ChatMessage { .init(role: .system, content: text) }
    public static func user(_ text: String) -> ChatMessage { .init(role: .user, content: text) }
    public static func assistant(_ text: String) -> ChatMessage { .init(role: .assistant, content: text) }
}
