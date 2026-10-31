import Foundation

/// 一条「模型接入」配置：自己命名，独立保存 base URL / API Key / 模型名。
/// 多条配置可以在面板里直接切换（输入框右侧的模型按钮）。
///
/// 存储见 `Settings.providerConfigs`（UserDefaults 里的 JSON 数组）。
public struct ProviderConfig: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case ollama
        case openAICompatible

        public var title: String {
            switch self {
            case .ollama: return "Ollama（本地）"
            case .openAICompatible: return "OpenAI 兼容"
            }
        }

        public var defaultBaseURL: String {
            switch self {
            case .ollama: return "http://127.0.0.1:11434"
            case .openAICompatible: return "https://api.openai.com/v1"
            }
        }

        /// 免费层价目表变动频繁，这里只放当前确认可用的默认值，用户随时可改
        public var defaultModel: String {
            switch self {
            case .ollama: return "qwen3:4b-instruct"
            case .openAICompatible: return "gpt-4o-mini"
            }
        }

        /// Ollama 跑在本机，不需要 key
        public var needsAPIKey: Bool { self != .ollama }

        /// 本地模型上下文窗口小、对长输入更敏感，用紧一点的上下文预算
        public var isLocal: Bool { self == .ollama }

        /// 能确定的窗口大小。Ollama 靠探测、OpenAI 兼容各家不同，都返回 nil。
        public var knownContextLength: Int? { nil }

        /// 设置页里 Base URL / 模型的输入提示
        public var baseURLHint: String {
            switch self {
            case .ollama: return "http://127.0.0.1:11434"
            case .openAICompatible: return "填到 /v1 或只填域名都可以"
            }
        }
    }

    /// 设置页和面板菜单按这三类组织。
    public enum Category: String, Codable, Sendable, CaseIterable {
        /// 本机推理，默认 Ollama，模型名手填
        case local
        /// 内置的免费通道（目前只有智谱），模型清单从接口拉
        case free
        /// 用户自填 Base URL + Key + 模型名
        case custom

        public var title: String {
            switch self {
            case .local: return "本地"
            case .free: return "免费"
            case .custom: return "自定义"
            }
        }
    }

    /// 内置项用固定 id，跨启动稳定
    public static let builtinOllamaID = UUID(uuidString: "0A11AB00-0000-4000-8000-00000000B002")!
    /// 智谱 GLM-4.7-Flash：官方标着永久免费，国内直连，不需要代理
    public static let builtinZhipuID = UUID(uuidString: "5A1B0C00-0000-4000-8000-00000000D004")!

    public var id: UUID
    /// 用户自己起的名字，例如「我的 Gemini」「公司网关」
    public var name: String
    public var kind: Kind
    public var baseURL: String
    public var apiKey: String
    public var model: String
    /// 内置项不允许删除
    public var isBuiltin: Bool
    /// 模型的上下文窗口（token 数）。nil = 未知，装配上下文时用保守默认。
    /// 可选字段：缺省即 nil，装配上下文时退回保守默认。
    public var contextLength: Int?
    /// 分类。nil 表示旧数据，读的时候按 kind/baseURL 推断。
    public var category: Category?
    /// 免费类从接口拉到的全部可用模型。面板菜单会把它们逐个列出来。
    public var cachedModels: [String]?

    public init(id: UUID = UUID(),
                name: String,
                kind: Kind,
                baseURL: String,
                apiKey: String = "",
                model: String,
                isBuiltin: Bool = false,
                contextLength: Int? = nil,
                category: Category? = nil,
                cachedModels: [String]? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.isBuiltin = isBuiltin
        self.contextLength = contextLength
        self.category = category
        self.cachedModels = cachedModels
    }

    /// 分类。没显式存过就按 kind 推断：Ollama 是本地，其余都是自定义。
    public var resolvedCategory: Category {
        if let category { return category }
        return kind == .ollama ? .local : .custom
    }

    /// 免费组内的展示顺序：智谱排最前，其余按名字。
    public var freeSortRank: Int {
        baseURL.lowercased().contains("bigmodel") ? 0 : 9
    }

    /// 面板菜单里要列出的模型。
    /// 本地和免费都展开同步来的全量清单；自定义类只返回当前模型。
    public var selectableModels: [String] {
        let expandable = resolvedCategory == .free || resolvedCategory == .local
        guard expandable, let cached = cachedModels, !cached.isEmpty else {
            return [model].filter { !$0.isEmpty }
        }
        return cached
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

    public func makeProvider(temperature: Double = 0.3,
                             disableThinking: Bool = false) -> LLMProvider {
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
                                            temperature: temperature,
                                            disableThinking: disableThinking)
        }
    }
}

public extension ProviderConfig {
    /// 首次启动的预置接入。智谱在前：它当前是唯一「不限 token 总量」的国内免费模型。
    static func builtins() -> [ProviderConfig] {
        [
            ProviderConfig(id: builtinZhipuID,
                           name: "智谱 GLM（免费）",
                           kind: .openAICompatible,
                           baseURL: "https://open.bigmodel.cn/api/paas/v4",
                           model: "glm-4.7-flash",
                           isBuiltin: true,
                           // GLM-4.7-Flash 是 200K 窗口
                           contextLength: 204_800,
                           category: .free),
            ProviderConfig(id: builtinOllamaID,
                           name: "Ollama 本地",
                           kind: .ollama,
                           baseURL: Kind.ollama.defaultBaseURL,
                           model: Kind.ollama.defaultModel,
                           isBuiltin: true,
                           category: .local),
        ]
    }
}
