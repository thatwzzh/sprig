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
        activeConfig.makeProvider()
    }

    static func selectProvider(id: UUID) {
        guard providerConfigs.contains(where: { $0.id == id }) else { return }
        activeProviderID = id
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
        // 接入在但缺窗口信息，也补一次——不然上下文预算会退回保守值
        if let index = providerConfigs.firstIndex(where: { $0.id == ProviderConfig.builtinOpenRouterFreeID }),
           providerConfigs[index].contextLength == nil {
            return true
        }
        guard let last = freeModelsLastSync else { return true }
        return Date().timeIntervalSince(last) >= 24 * 60 * 60
    }

    /// 拉取并维护 OpenRouter 免费接入。
    /// 已存在这条接入时只做维护：当前选的模型如果下架了就换成清单里的第一个，否则不动用户的选择。
    /// 返回是否成功拿到清单（网络失败不算异常，静默返回 false）。
    @discardableResult
    @MainActor
    static func syncFreeModels() async -> Bool {
        guard let models = try? await FreeModelCatalog.openRouterFreeModels(), !models.isEmpty else {
            return false
        }

        var configs = providerConfigs
        let preferred = FreeModelCatalog.preferred(from: models)

        if let index = configs.firstIndex(where: { $0.id == ProviderConfig.builtinOpenRouterFreeID }) {
            let inList = models.contains { $0.id == configs[index].model }
            if !inList, let preferred {
                configs[index].model = preferred.id
                configs[index].contextLength = preferred.contextLength
            } else if configs[index].contextLength == nil,
                      let current = models.first(where: { $0.id == configs[index].model }) {
                // 之前没记窗口的，这次补上
                configs[index].contextLength = current.contextLength
            }
            // 名字被用户改过就不覆盖
            if configs[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                configs[index].name = "OpenRouter 免费"
            }
        } else if let preferred {
            configs.append(ProviderConfig.openRouterFree(model: preferred.id,
                                                         contextLength: preferred.contextLength))
        }

        providerConfigs = configs
        UserDefaults.standard.set(Date(), forKey: freeModelsLastSyncKey)
        UserDefaults.standard.set(models.count, forKey: freeModelsCountKey)
        return true
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
