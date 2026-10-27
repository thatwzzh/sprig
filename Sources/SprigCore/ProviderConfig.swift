import Foundation

/// 一条「模型接入」配置：自己命名，独立保存 base URL / API Key / 模型名。
/// 多条配置可以在面板里直接切换（输入框右侧的模型按钮）。
///
/// 存储见 `Settings.providerConfigs`（UserDefaults 里的 JSON 数组）。
public struct ProviderConfig: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case gemini
        case ollama
        case openAICompatible

        public var title: String {
            switch self {
            case .gemini: return "Google Gemini"
            case .ollama: return "Ollama（本地）"
            case .openAICompatible: return "OpenAI 兼容"
            }
        }

        public var defaultBaseURL: String {
            switch self {
            case .gemini: return "https://generativelanguage.googleapis.com"
            case .ollama: return "http://127.0.0.1:11434"
            case .openAICompatible: return "https://api.openai.com/v1"
            }
        }

        /// 免费层价目表变动频繁，这里只放当前确认可用的默认值，用户随时可改
        public var defaultModel: String {
            switch self {
            case .gemini: return "gemini-2.5-flash"
            case .ollama: return "qwen3:4b-instruct"
            case .openAICompatible: return "gpt-4o-mini"
            }
        }

        /// Ollama 跑在本机，不需要 key
        public var needsAPIKey: Bool { self != .ollama }

        /// 本地模型上下文窗口小、对长输入更敏感，用紧一点的上下文预算
        public var isLocal: Bool { self == .ollama }

        /// 设置页里 Base URL / 模型的输入提示
        public var baseURLHint: String {
            switch self {
            case .gemini: return "https://generativelanguage.googleapis.com（可留空用默认）"
            case .ollama: return "http://127.0.0.1:11434"
            case .openAICompatible: return "填到 /v1 或只填域名都可以"
            }
        }
    }

    /// 内置项用固定 id，跨启动稳定
    public static let builtinGeminiID = UUID(uuidString: "5A1B0C00-0000-4000-8000-00000000A001")!
    public static let builtinOllamaID = UUID(uuidString: "0A11AB00-0000-4000-8000-00000000B002")!

    public var id: UUID
    /// 用户自己起的名字，例如「我的 Gemini」「公司网关」
    public var name: String
    public var kind: Kind
    public var baseURL: String
    public var apiKey: String
    public var model: String
    /// 内置项不允许删除
    public var isBuiltin: Bool

    public init(id: UUID = UUID(),
                name: String,
                kind: Kind,
                baseURL: String,
                apiKey: String = "",
                model: String,
                isBuiltin: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.isBuiltin = isBuiltin
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.title : trimmed
    }

    /// 模型名去掉 `models/` 前缀，用于按钮/菜单展示
    public var modelLabel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.hasPrefix("models/") ? String(trimmed.dropFirst("models/".count)) : trimmed
        return name.isEmpty ? kind.defaultModel : name
    }

    /// 缺 key 或模型名为空时视为没配好，提问前就会拦下来
    public var isConfigured: Bool {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return false }
        guard kind.needsAPIKey else { return true }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func makeProvider(temperature: Double = 0.3) -> LLMProvider {
        let rawBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: rawBase) ?? URL(string: kind.defaultBaseURL)!
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        switch kind {
        case .ollama:
            return OllamaProvider(id: id.uuidString,
                                  displayName: displayName,
                                  baseURL: url,
                                  model: trimmedModel.isEmpty ? kind.defaultModel : trimmedModel,
                                  temperature: temperature)
        case .openAICompatible:
            return OpenAICompatibleProvider(id: id.uuidString,
                                            displayName: displayName,
                                            baseURL: url,
                                            apiKey: key,
                                            model: trimmedModel.isEmpty ? kind.defaultModel : trimmedModel,
                                            temperature: temperature)
        case .gemini:
            return GeminiProvider(id: id.uuidString,
                                  displayName: displayName,
                                  baseURL: url,
                                  apiKey: key,
                                  model: trimmedModel.isEmpty ? kind.defaultModel : trimmedModel,
                                  temperature: temperature)
        }
    }
}

public extension ProviderConfig {
    /// 首次启动的预置接入。Gemini 在前：新用户开箱就有可用的免费模型。
    static func builtins(ollamaModel: String, ollamaBaseURL: String) -> [ProviderConfig] {
        [
            ProviderConfig(id: builtinGeminiID,
                           name: "Gemini（免费）",
                           kind: .gemini,
                           baseURL: Kind.gemini.defaultBaseURL,
                           model: Kind.gemini.defaultModel,
                           isBuiltin: true),
            ProviderConfig(id: builtinOllamaID,
                           name: "Ollama 本地",
                           kind: .ollama,
                           baseURL: ollamaBaseURL.isEmpty ? Kind.ollama.defaultBaseURL : ollamaBaseURL,
                           model: ollamaModel.isEmpty ? Kind.ollama.defaultModel : ollamaModel,
                           isBuiltin: true),
        ]
    }
}
