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
            case .gemini: return "gemini-3.8-flash"
            case .ollama: return "qwen3:4b-instruct"
            case .openAICompatible: return "gpt-4o-mini"
            }
        }

        /// Ollama 跑在本机，不需要 key
        public var needsAPIKey: Bool { self != .ollama }

        /// 本地模型上下文窗口小、对长输入更敏感，用紧一点的上下文预算
        public var isLocal: Bool { self == .ollama }

        /// 能确定的窗口大小。Ollama 靠探测、OpenAI 兼容各家不同，都返回 nil。
        public var knownContextLength: Int? {
            switch self {
            case .gemini: return 1_048_576   // gemini-2.5-flash
            case .ollama, .openAICompatible: return nil
            }
        }

        /// 设置页里 Base URL / 模型的输入提示
        public var baseURLHint: String {
            switch self {
            case .gemini: return "https://generativelanguage.googleapis.com（可留空用默认）"
            case .ollama: return "http://127.0.0.1:11434"
            case .openAICompatible: return "填到 /v1 或只填域名都可以"
            }
        }
    }

    /// 设置页和面板菜单按这三类组织。
    public enum Category: String, Codable, Sendable, CaseIterable {
        /// 本机推理，默认 Ollama，模型名手填
        case local
        /// Gemini / OpenRouter，模型清单从接口拉
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
    public static let builtinGeminiID = UUID(uuidString: "5A1B0C00-0000-4000-8000-00000000A001")!
    public static let builtinOllamaID = UUID(uuidString: "0A11AB00-0000-4000-8000-00000000B002")!
    /// OpenRouter 免费模型：由 FreeModelCatalog 自动创建并每日维护，id 固定便于幂等更新
    public static let builtinOpenRouterFreeID = UUID(uuidString: "5A1B0C00-0000-4000-8000-00000000C003")!

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
    /// 可选字段，旧数据解码出来就是 nil，不需要迁移。
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

    /// 读取时用的分类。旧配置没有这个字段，按 kind 和 baseURL 推断：
    /// Ollama 是本地，Gemini 和 OpenRouter 归免费，其余 OpenAI 兼容都是自定义。
    public var resolvedCategory: Category {
        if let category { return category }
        switch kind {
        case .ollama:
            return .local
        case .gemini:
            return .free
        case .openAICompatible:
            return baseURL.lowercased().contains("openrouter") ? .free : .custom
        }
    }

    /// 免费类要展开的模型清单；非免费类只返回当前模型
    public var selectableModels: [String] {
        guard resolvedCategory == .free,
              let cached = cachedModels, !cached.isEmpty else {
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
        case .gemini:
            return GeminiProvider(id: id.uuidString,
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
    /// 首次启动的预置接入。Gemini 在前：新用户开箱就有可用的免费模型。
    static func builtins(ollamaModel: String, ollamaBaseURL: String) -> [ProviderConfig] {
        [
            ProviderConfig(id: builtinGeminiID,
                           name: "Gemini（免费）",
                           kind: .gemini,
                           baseURL: Kind.gemini.defaultBaseURL,
                           model: Kind.gemini.defaultModel,
                           isBuiltin: true,
                           // gemini-2.5-flash 是 1M 窗口，这是内置项里少数能确定的值
                           contextLength: 1_048_576,
                           category: .free),
            ProviderConfig(id: builtinOllamaID,
                           name: "Ollama 本地",
                           kind: .ollama,
                           baseURL: ollamaBaseURL.isEmpty ? Kind.ollama.defaultBaseURL : ollamaBaseURL,
                           model: ollamaModel.isEmpty ? Kind.ollama.defaultModel : ollamaModel,
                           isBuiltin: true,
                           category: .local),
        ]
    }

    /// OpenRouter 免费模型接入。由 `Settings.syncFreeModels()` 自动创建并每日维护。
    /// 标成内置是为了让每日同步幂等：用户不会把它删掉、第二天又冒出来。
    public static func openRouterFree(model: String, contextLength: Int? = nil) -> ProviderConfig {
        ProviderConfig(id: builtinOpenRouterFreeID,
                       name: "OpenRouter 免费",
                       kind: .openAICompatible,
                       baseURL: FreeModelCatalog.openRouterBaseURL,
                       model: model,
                       isBuiltin: true,
                       contextLength: contextLength,
                       category: .free)
    }

    /// 这条接入该去哪里领 API Key。设置页据此显示可点的「去获取」。
    /// 只给确定能免费拿到的地址；不认识的 OpenAI 兼容网关返回 nil，不瞎猜。
    public var keyHelp: (text: String, url: URL)? {
        let base = baseURL.lowercased()
        if base.contains("openrouter") {
            return ("在 openrouter.ai/keys 免费领一个 Key（免费层约 20 次/分钟、50 次/天）",
                    URL(string: "https://openrouter.ai/keys")!)
        }
        switch kind {
        case .gemini:
            return ("在 Google AI Studio 免费领一个 Key（免费层约 10–15 次/分钟）",
                    URL(string: "https://aistudio.google.com/apikey")!)
        case .ollama, .openAICompatible:
            return nil
        }
    }
}
