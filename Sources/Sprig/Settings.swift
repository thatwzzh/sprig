import Foundation
import SprigCore

extension Notification.Name {
    /// 模型接入配置变化（设置页改动、切换模型、新增/删除接入）
    static let sprigProvidersDidChange = Notification.Name("sprigProvidersDidChange")
}

enum Settings {
    private static let providersKey = "providerConfigs"
    private static let activeProviderKey = "activeProviderID"
    private static let cardsDirectoryKey = "cardsDirectory"
    private static let migratedKey = "didMigrateFromLegacyBundle"

    /// 旧版本只有单模型设置。留着只做两件事：迁移老配置、判断「是不是老用户」。
    private static let legacyModelKey = "ollamaModel"
    private static let legacyBaseURLKey = "ollamaBaseURL"

    // MARK: - 模型接入

    /// 全部接入配置。没存过时给出内置的 Gemini + Ollama 两条。
    ///
    /// 加了内存缓存：这个 getter 在流式发起的路径上被间接调用两次
    /// （`activeConfig` 里先取 `providerConfigs`、再取 `activeProviderID`，后者又取一遍），
    /// 每次都做一次 JSON 解码没必要。写入时同步更新缓存，所以不会读到旧值。
    static var providerConfigs: [ProviderConfig] {
        get {
            configsLock.lock()
            if let cached = configsCache {
                configsLock.unlock()
                return cached
            }
            configsLock.unlock()

            let value = loadProviderConfigs()

            configsLock.lock()
            configsCache = value
            configsLock.unlock()
            return value
        }
        set {
            let value = newValue.isEmpty
                ? ProviderConfig.builtins(ollamaModel: legacyModel, ollamaBaseURL: legacyBaseURL)
                : newValue
            guard let data = try? JSONEncoder().encode(value) else { return }
            UserDefaults.standard.set(data, forKey: providersKey)
            // 落盘成功后再更新缓存，避免编码失败时缓存和磁盘不一致
            configsLock.lock()
            configsCache = value
            configsLock.unlock()
            NotificationCenter.default.post(name: .sprigProvidersDidChange, object: nil)
        }
    }

    private static let configsLock = NSLock()
    nonisolated(unsafe) private static var configsCache: [ProviderConfig]?

    private static func loadProviderConfigs() -> [ProviderConfig] {
        if let data = UserDefaults.standard.data(forKey: providersKey),
           let decoded = try? JSONDecoder().decode([ProviderConfig].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        return ProviderConfig.builtins(ollamaModel: legacyModel, ollamaBaseURL: legacyBaseURL)
    }

    /// 当前使用的接入。存的是 UUID 字符串。
    static var activeProviderID: UUID {
        get {
            let configs = providerConfigs
            if let raw = UserDefaults.standard.string(forKey: activeProviderKey),
               let uuid = UUID(uuidString: raw),
               configs.contains(where: { $0.id == uuid }) {
                return uuid
            }
            return defaultProviderID
        }
        set {
            UserDefaults.standard.set(newValue.uuidString, forKey: activeProviderKey)
            NotificationCenter.default.post(name: .sprigProvidersDidChange, object: nil)
        }
    }

    /// 老用户（上一版写死 Ollama）继续用 Ollama，新装用户默认免费 Gemini。
    private static var defaultProviderID: UUID {
        if UserDefaults.standard.object(forKey: legacyModelKey) != nil {
            return ProviderConfig.builtinOllamaID
        }
        return ProviderConfig.builtinGeminiID
    }

    static var activeConfig: ProviderConfig {
        let configs = providerConfigs
        let id = activeProviderID
        var config = configs.first(where: { $0.id == id }) ?? configs[0]
        // 便于 --headless 调试时临时换模型：SPRIG_MODEL=gemini-2.5-flash
        // 环境变量只在进程内变，读一次就够；每次访问 ProcessInfo.environment 都要重建整个字典
        if let override = modelOverride { config.model = override }
        return config
    }

    private static let modelOverride: String? = {
        let env = ProcessInfo.processInfo.environment
        guard let value = env["SPRIG_MODEL"] ?? env["CONCEPTLENS_MODEL"], !value.isEmpty else {
            return nil
        }
        return value
    }()

    static var provider: LLMProvider {
        activeConfig.makeProvider(disableThinking: disableThinking)
    }

    private static let disableThinkingKey = "disableThinking"

    /// 默认关闭推理模型的思考链——知识问答要的是快和直接，思考过程既慢又没用。
    /// 用 object(forKey:) 判存在，因为「没存过」要当作 true，而 bool(forKey:) 会返回 false。
    static var disableThinking: Bool {
        get {
            guard UserDefaults.standard.object(forKey: disableThinkingKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: disableThinkingKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: disableThinkingKey)
            NotificationCenter.default.post(name: .sprigProvidersDidChange, object: nil)
        }
    }

    static func selectProvider(id: UUID) {
        guard providerConfigs.contains(where: { $0.id == id }) else { return }
        activeProviderID = id
    }

    /// 保证「本地」分类始终有一条 Ollama。
    /// 用户可能把内置那条改成别的协议（改 Base URL 到 api.openai.com 之类），
    /// 那样本地区域会空着——本地推理是常用入口，不能让它消失。
    static func ensureLocalConfig() {
        var configs = providerConfigs

        // 按 kind 判断而不是 resolvedCategory：category 字段可能是 nil（旧数据）
        // 或被中途改过，只靠它会在每次启动时都判定"没有本地"，越补越多。
        if let index = configs.firstIndex(where: { $0.kind == .ollama }) {
            // 已有就不再新增，只把分类补正
            guard configs[index].category != .local else { return }
            configs[index].category = .local
            providerConfigs = configs
            return
        }

        configs.append(ProviderConfig(name: "Ollama 本地",
                                      kind: .ollama,
                                      baseURL: ProviderConfig.Kind.ollama.defaultBaseURL,
                                      model: ProviderConfig.Kind.ollama.defaultModel,
                                      category: .local))
        providerConfigs = configs
    }

    /// 老用户升级后没有智谱这条内置接入，补一条（key 留空，等他去填）。
    /// 只在完全没有智谱配置时才加，避免和用户自建的重复。
    static func ensureZhipuConfig() {
        guard !providerConfigs.contains(where: { $0.baseURL.lowercased().contains("bigmodel") }) else { return }
        var configs = providerConfigs
        configs.append(ProviderConfig(id: ProviderConfig.builtinZhipuID,
                                      name: "智谱 GLM（免费）",
                                      kind: .openAICompatible,
                                      baseURL: "https://open.bigmodel.cn/api/paas/v4",
                                      model: "glm-4.7-flash",
                                      isBuiltin: true,
                                      contextLength: 204_800,
                                      category: .free))
        providerConfigs = configs
    }

    /// Gemini 下线旧模型时（如 2.5-flash → 3.8-flash），存量配置不会自动跟着换，
    /// 否则调用会一直 404。这里把已知下线的换成本代默认值。
    static func migrateRetiredGeminiModels() {
        let retired = ["gemini-2.5-flash", "gemini-2.5-pro"]
        var configs = providerConfigs
        var changed = false
        for index in configs.indices where configs[index].kind == .gemini {
            guard retired.contains(configs[index].model) else { continue }
            configs[index].model = ProviderConfig.Kind.gemini.defaultModel
            changed = true
        }
        guard changed else { return }
        providerConfigs = configs
    }

    /// 老配置里没有 contextLength 字段，按 kind 能确定的补上。
    /// 不补的话，用云端模型时上下文预算会退回保守的 12000 字，白白浪费窗口。
    static func backfillContextLengths() {
        var configs = providerConfigs
        var changed = false
        for index in configs.indices where configs[index].contextLength == nil {
            guard let known = configs[index].kind.knownContextLength else { continue }
            configs[index].contextLength = known
            changed = true
        }
        guard changed else { return }
        providerConfigs = configs
    }

    /// 把探测到的 Ollama 模型写进内置 Ollama 项。
    /// 只在用户没手动改过（仍是默认模型名）时生效，避免覆盖用户设置。
    static func adoptDetectedOllamaModels(_ models: [String], contextLengths: [String: Int] = [:]) {
        guard let preferred = models.first(where: { $0.hasPrefix("qwen3") }) ?? models.first else { return }
        var configs = providerConfigs
        guard let index = configs.firstIndex(where: { $0.kind == .ollama }) else { return }

        var changed = false
        // 模型名只在还是出厂默认时替换，别覆盖用户自己选的
        if configs[index].model == ProviderConfig.Kind.ollama.defaultModel {
            configs[index].model = preferred
            changed = true
        }
        // 上下文窗口缺失就补上；已知的不覆盖
        if configs[index].contextLength == nil,
           let context = contextLengths[configs[index].model] {
            configs[index].contextLength = context
            changed = true
        }
        guard changed else { return }
        providerConfigs = configs
    }

    // MARK: - 联网搜索

    private static let webSearchEnabledKey = "webSearchEnabled"
    private static let searchBackendKey = "searchBackend"
    private static let tavilyAPIKeyKey = "tavilyAPIKey"
    private static let deepseekSearchKeyKey = "deepseekSearchAPIKey"
    private static let customProxyKey = "customProxy"

    /// 全局 HTTP 代理，形如 http://127.0.0.1:7890。空表示跟随系统设置。
    /// 改完立刻重建 URLSession，下一次请求就生效。
    static var customProxy: String {
        get { UserDefaults.standard.string(forKey: customProxyKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: customProxyKey)
            HTTPClient.proxy = trimmed
        }
    }
    /// 早期只有一个搜索 Key，切后端时留作兼容
    private static let legacyWebSearchKey = "webSearchAPIKey"

    /// 是否让模型自己决定要不要联网搜。默认关——开着会花搜索额度。
    static var webSearchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: webSearchEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: webSearchEnabledKey)
            NotificationCenter.default.post(name: .sprigProvidersDidChange, object: nil)
        }
    }

    static var searchBackend: SearchBackend {
        get {
            guard let raw = UserDefaults.standard.string(forKey: searchBackendKey),
                  let backend = SearchBackend(rawValue: raw) else { return .tavily }
            return backend
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: searchBackendKey)
            NotificationCenter.default.post(name: .sprigProvidersDidChange, object: nil)
        }
    }

    /// 当前后端对应的 Key。两个后端各存一份，切来切去不会互相覆盖。
    static var webSearchAPIKey: String {
        get {
            switch searchBackend {
            case .tavily:
                // 旧版本只有一个搜索 Key，第一次读时接过来
                if let value = UserDefaults.standard.string(forKey: tavilyAPIKeyKey) {
                    return value
                }
                return UserDefaults.standard.string(forKey: legacyWebSearchKey) ?? ""
            case .deepseek:
                return UserDefaults.standard.string(forKey: deepseekSearchKeyKey) ?? ""
            }
        }
        set {
            switch searchBackend {
            case .tavily:
                UserDefaults.standard.set(newValue, forKey: tavilyAPIKeyKey)
            case .deepseek:
                UserDefaults.standard.set(newValue, forKey: deepseekSearchKeyKey)
            }
        }
    }

    /// 真正可用的条件：开关打开 + 当前后端有 Key
    static var webSearchReady: Bool {
        webSearchEnabled
            && !webSearchAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 免费模型（OpenRouter）

    private static let freeModelsLastSyncKey = "freeModelsLastSync"
    private static let freeModelsCountKey = "freeModelsCount"

    /// 上次同步免费模型的时间
    static var freeModelsLastSync: Date? {
        UserDefaults.standard.object(forKey: freeModelsLastSyncKey) as? Date
    }

    /// 上次同步时拿到的免费模型数量
    static var freeModelsCount: Int {
        UserDefaults.standard.integer(forKey: freeModelsCountKey)
    }

    /// 是否已经有一条 OpenRouter 免费接入
    static var hasFreeModelConfig: Bool {
        providerConfigs.contains { $0.id == ProviderConfig.builtinOpenRouterFreeID }
    }

    /// 超过一天就该重新拉一次
    static var needsFreeModelSync: Bool {
        // 本地和免费都要维护清单：没同步过就补一次
        for config in providerConfigs
        where config.resolvedCategory == .free || config.resolvedCategory == .local {
            if config.cachedModels?.isEmpty ?? true { return true }
            if config.resolvedCategory == .free, config.contextLength == nil { return true }
        }
        guard let last = freeModelsLastSync else { return true }
        return Date().timeIntervalSince(last) >= 24 * 60 * 60
    }

    /// 同步某个分类下的模型清单（本地 / 免费各管各的，互不影响）。
    ///
    /// 拉完立刻探一遍：只把真正能调通的写回 cachedModels。
    /// 429 算「暂时不可用」但仍然保留——那是上游容量问题，过几分钟就好，
    /// 剔掉会让列表反复抖动；404/403/400 这类是模型本身没了或没权限，直接剔除。
    @MainActor
    @discardableResult
    static func syncModels(in category: ProviderConfig.Category) async -> (total: Int, usable: Int) {
        var configs = providerConfigs
        var total = 0
        var usable = 0
        var touched = false

        for index in configs.indices where configs[index].resolvedCategory == category {
            let config = configs[index]
            let models = await fetchFreeModels(for: config)
            guard !models.isEmpty else { continue }
            total = models.count

            // 只有 OpenAI 兼容能这样探活。Gemini 的接口形状不同，
            // 逐个探会把免费额度打光；Ollama 的模型就在本机，不存在调不通。
            var keep = models
            if config.kind == .openAICompatible {
                let results = await ModelProbe.probe(models: models, config: config)
                let good = results.filter { $0.ok || $0.isQuotaIssue }.map(\.model)
                // 一个都没通过说明这次探测本身有问题，别把清单清空
                if !good.isEmpty { keep = good }
                usable = keep.count
                for result in results where !result.ok {
                    print("[sync] \(config.displayName) \(result.model) → \(result.summary)")
                }
            } else {
                usable = keep.count
            }

            configs[index].category = category
            configs[index].cachedModels = keep
            if !keep.contains(configs[index].model) {
                configs[index].model = keep[0]
            }
            if configs[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                configs[index].name = configs[index].kind.title
            }
            touched = true
        }

        guard touched else { return (0, 0) }
        providerConfigs = configs
        UserDefaults.standard.set(Date(), forKey: freeModelsLastSyncKey)
        UserDefaults.standard.set(usable, forKey: freeModelsCountKey)
        return (total, usable)
    }

    /// 启动时用：本地和免费都刷一遍
    @discardableResult
    static func syncAllModels() async -> Bool {
        let local = await syncModels(in: .local)
        let free = await syncModels(in: .free)
        return local.total + free.total > 0
    }

    @MainActor
    private static func fetchFreeModels(for config: ProviderConfig) async -> [String] {
        switch config.kind {
        case .ollama:
            let base = URL(string: config.baseURL) ?? URL(string: ProviderConfig.Kind.ollama.defaultBaseURL)!
            return await OllamaProvider.availableModels(baseURL: base)
        case .gemini:
            let all = await GeminiProvider.availableModels(apiKey: config.apiKey)
            // 列表里混着 tts / image / live / native-audio 这些专用模型，不能拿来对话
            let blocked = ["tts", "image", "live", "native-audio", "deep-research", "lyria", "embedding"]
            return all.filter { name in
                let lower = name.lowercased()
                guard lower.contains("flash") || lower.contains("pro") else { return false }
                return !blocked.contains { lower.contains($0) }
            }
        case .openAICompatible:
            // 只有 OpenRouter 走它那套「免费清单 + 非对话模型过滤」。
            // 其他 OpenAI 兼容网关（智谱等）走标准的 /models —— 之前一律按
            // OpenRouter 处理，导致智谱拉回了 OpenRouter 的模型名。
            if config.baseURL.lowercased().contains("openrouter") {
                guard let free = try? await FreeModelCatalog.openRouterFreeModels() else { return [] }
                return free
                    .filter { !FreeModelCatalog.isNonChatModel($0.id) }
                    .map(\.id)
            }
            let base = URL(string: config.baseURL)
                ?? URL(string: ProviderConfig.Kind.openAICompatible.defaultBaseURL)!
            let options = await OpenAICompatibleProvider.modelOptions(baseURL: base,
                                                                     apiKey: config.apiKey)
            return options.map(\.id)
        }
    }

    // MARK: - 知识库目录

    /// 知识库（卡片 JSON）所在目录，默认 ~/Documents/Sprig
    static var defaultCardsDirectory: URL {
        documentsDirectory.appendingPathComponent(AppInfo.englishName, isDirectory: true)
    }

    /// 上一版默认目录 ~/Documents/a，只用于把老数据搬到新默认位置
    private static var previousDefaultCardsDirectory: URL {
        documentsDirectory.appendingPathComponent("a", isDirectory: true)
    }

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Documents", isDirectory: true)
    }

    static var cardsDirectory: URL {
        get {
            guard let raw = UserDefaults.standard.string(forKey: cardsDirectoryKey), !raw.isEmpty else {
                return defaultCardsDirectory
            }
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: cardsDirectoryKey) }
    }

    // MARK: - 旧设置

    private static var legacyModel: String {
        UserDefaults.standard.string(forKey: legacyModelKey) ?? ""
    }

    private static var legacyBaseURL: String {
        UserDefaults.standard.string(forKey: legacyBaseURLKey) ?? ""
    }

    /// 包名从 com.catking.conceptlens 换成 com.catking.sprig 后，UserDefaults 域也跟着换了，
    /// 这里把旧的模型 / 地址 / 目录 / 已录制的快捷键搬过来，避免升级后设置被重置。
    /// 必须在读取任何设置、注册快捷键之前调用。
    static func migrateLegacyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)

        for identifier in AppInfo.legacyBundleIdentifiers {
            guard let legacy = UserDefaults(suiteName: identifier) else { continue }
            for (key, value) in legacy.dictionaryRepresentation() where isMigratableKey(key) {
                guard defaults.object(forKey: key) == nil else { continue }
                defaults.set(value, forKey: key)
            }
            defaults.set(identifier, forKey: "migratedFromBundle")
            break   // 只搬最近的一个有数据的旧域
        }
    }

    /// 系统写入的键（NS*/Apple*）不搬，其余自有设置整份搬过来
    private static func isMigratableKey(_ key: String) -> Bool {
        if key.hasPrefix("NS") || key.hasPrefix("Apple") || key == migratedKey { return false }
        return true
    }

    /// 默认目录从 ~/Documents/a 换成 ~/Documents/Sprig 后，把旧默认目录里的库搬过去。
    /// 用户自己选过目录时不碰。
    static func prepareCardsDirectory() {
        guard UserDefaults.standard.string(forKey: cardsDirectoryKey) == nil else { return }

        let manager = FileManager.default
        let targetDirectory = defaultCardsDirectory
        let target = targetDirectory.appendingPathComponent(CardStore.fileName)
        guard !manager.fileExists(atPath: target.path) else { return }

        let source = previousDefaultCardsDirectory.appendingPathComponent(CardStore.fileName)
        guard manager.fileExists(atPath: source.path) else { return }

        try? manager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try? manager.copyItem(at: source, to: target)
    }
}
