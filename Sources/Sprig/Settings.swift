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

    // MARK: - 模型接入

    /// 全部接入配置。没存过时给出内置的智谱 + Ollama 两条。
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
            let value = newValue.isEmpty ? ProviderConfig.builtins() : newValue
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
        return ProviderConfig.builtins()
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

    /// 默认用智谱的免费型号。
    private static var defaultProviderID: UUID {
        ProviderConfig.builtinZhipuID
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

    private static let readingThemeKey = "readingTheme"

    /// 答案区阅读主题：default / github / newsprint
    static var readingTheme: String {
        get { UserDefaults.standard.string(forKey: readingThemeKey) ?? MarkdownTheme.default.id }
        set { UserDefaults.standard.set(newValue, forKey: readingThemeKey) }
    }

    private static let disableThinkingKey = "disableThinking"
    private static let agentConfigsKey = "agentConfigs"
    private static let activeAgentKey = "activeAgentID"
    private static let dismissedAgentsKey = "dismissedAgentPresets"
    private static let agentWorkspaceKey = "agentWorkspace"
    private static let usesAgentKey = "usesAcpAgent"

    // MARK: - Agent

    /// 全部 agent 配置。没存过时把本机检测到的直接列出来——用户不用先「添加」。
    static var agentConfigs: [AgentConfig] {
        get {
            if let data = UserDefaults.standard.data(forKey: agentConfigsKey),
               let decoded = try? JSONDecoder().decode([AgentConfig].self, from: data) {
                // 早期版本把模型选成了 auto（agent 自己路由、又慢又不确定），这里清成「跟随默认」
                guard decoded.contains(where: { $0.modelID?.lowercased().hasPrefix("auto") == true }) else {
                    return decoded
                }
                let cleaned = decoded.map { config -> AgentConfig in
                    guard config.modelID?.lowercased().hasPrefix("auto") == true else { return config }
                    var copy = config
                    copy.modelID = nil
                    copy.modelLabel = nil
                    copy.modelMaxInput = nil
                    return copy
                }
                if let encoded = try? JSONEncoder().encode(cleaned) {
                    UserDefaults.standard.set(encoded, forKey: agentConfigsKey)
                }
                return cleaned
            }
            // 第一次读：先按本机检测结果铺一份，并且**立刻落盘**。
            // 不落盘的话每次读都会生成新 UUID，选中的那条转眼就找不到了。
            let detected = AgentDetector.detect()
            if let data = try? JSONEncoder().encode(detected) {
                UserDefaults.standard.set(data, forKey: agentConfigsKey)
            }
            return detected
        }
        set {
            let value = newValue
            guard let data = try? JSONEncoder().encode(value) else { return }
            UserDefaults.standard.set(data, forKey: agentConfigsKey)
            if let id = activeAgentID, !value.contains(where: { $0.id == id }) {
                UserDefaults.standard.removeObject(forKey: activeAgentKey)
            }
            NotificationCenter.default.post(name: .sprigProvidersDidChange, object: nil)
        }
    }

    /// 把新装上的 agent 并进列表，并清理已经失效的删除记录。
    ///
    /// 删除一个检测项时记的是预设 id；这里每次检测都会回头看一眼那个预设**现在还装不装**：
    /// 已经卸载的就把记录清掉，于是重装之后它能自己回来（用户要的「重装自动恢复」）。
    static func syncDetectedAgents() {
        let detected = AgentDetector.detect()
        let detectedPresets = Set(detected.compactMap(\.presetID))
        var dismissed = UserDefaults.standard.stringArray(forKey: dismissedAgentsKey) ?? []
        let alive = dismissed.filter { detectedPresets.contains($0) }
        if alive != dismissed {
            dismissed = alive
            UserDefaults.standard.set(dismissed, forKey: dismissedAgentsKey)
        }

        var configs = agentConfigs
        var changed = false
        for item in detected {
            if let preset = item.presetID, dismissed.contains(preset) { continue }
            if let index = configs.firstIndex(where: {
                $0.command == item.command || ($0.presetID != nil && $0.presetID == item.presetID)
            }) {
                // 检测项的名字和命令在弹窗里是只读的，所以每次都以预设为准刷新一遍：
                // 预设改名、或 app 换了位置，标签跟着变。
                guard configs[index].presetID == item.presetID else { continue }
                if configs[index].name != item.name { configs[index].name = item.name; changed = true }
                if configs[index].command != item.command { configs[index].command = item.command; changed = true }
                continue
            }
            configs.append(item)
            changed = true
        }
        if changed { agentConfigs = configs }
    }

    /// 删掉一条配置。自动检测出来的记下预设 id，下次检测不再加回来。
    static func removeAgent(id: UUID) {
        var configs = agentConfigs
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return }
        let removed = configs.remove(at: index)
        if let preset = removed.presetID {
            var dismissed = UserDefaults.standard.stringArray(forKey: dismissedAgentsKey) ?? []
            if !dismissed.contains(preset) { dismissed.append(preset) }
            UserDefaults.standard.set(dismissed, forKey: dismissedAgentsKey)
        }
        agentConfigs = configs
    }

    static func upsertAgent(_ config: AgentConfig) {
        var configs = agentConfigs
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
        } else {
            configs.append(config)
        }
        agentConfigs = configs
    }

    /// 每个 agent 上次读到的模型清单。存在 UserDefaults 里，重开设置页不用再握手一次。
    static func cachedModels(for id: UUID) -> [AcpModel] {
        guard let data = UserDefaults.standard.data(forKey: modelsKey(for: id)),
              let list = try? JSONDecoder().decode([AcpModel].self, from: data) else { return [] }
        return list
    }

    static func setCachedModels(_ models: [AcpModel], for id: UUID) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        UserDefaults.standard.set(data, forKey: modelsKey(for: id))
    }

    private static func modelsKey(for id: UUID) -> String {
        "agentModels.\(id.uuidString)"
    }

    /// agent 暴露的会话选项（思考强度等），和模型清单一起缓存
    static func cachedOptions(for id: UUID) -> [AcpConfigOption] {
        guard let data = UserDefaults.standard.data(forKey: optionsKey(for: id)),
              let list = try? JSONDecoder().decode([AcpConfigOption].self, from: data) else { return [] }
        return list
    }

    static func setCachedOptions(_ options: [AcpConfigOption], for id: UUID) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        UserDefaults.standard.set(data, forKey: optionsKey(for: id))
    }

    private static func optionsKey(for id: UUID) -> String {
        "agentOptions.\(id.uuidString)"
    }

    /// 面板当前用哪一条。存 UUID 字符串。
    static var activeAgentID: UUID? {
        get {
            let configs = agentConfigs
            guard !configs.isEmpty else { return nil }
            if let raw = UserDefaults.standard.string(forKey: activeAgentKey),
               let uuid = UUID(uuidString: raw),
               configs.contains(where: { $0.id == uuid }) {
                return uuid
            }
            return configs[0].id
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: activeAgentKey)
            } else {
                UserDefaults.standard.removeObject(forKey: activeAgentKey)
            }
            NotificationCenter.default.post(name: .sprigProvidersDidChange, object: nil)
        }
    }

    static var activeAgent: AgentConfig? {
        let configs = agentConfigs
        guard !configs.isEmpty else { return nil }
        guard let id = activeAgentID else { return configs.first }
        return configs.first { $0.id == id } ?? configs.first
    }

    /// 面板当前是把问题交给 ACP agent，而不是交给上面的模型接入。
    static var usesAgent: Bool {
        get { UserDefaults.standard.bool(forKey: usesAgentKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: usesAgentKey)
            NotificationCenter.default.post(name: .sprigProvidersDidChange, object: nil)
        }
    }

    /// 当前 agent 的启动命令。旧代码只认这一个值，继续给它。
    static var acpCommand: String {
        get { activeAgent?.command ?? "" }
        set {
            var configs = agentConfigs
            guard let id = activeAgentID, let index = configs.firstIndex(where: { $0.id == id }) else { return }
            configs[index].command = newValue
            agentConfigs = configs
        }
    }

    /// 当前 agent 的工作目录。空字符串表示用默认目录。
    ///
    /// 所有 agent 共用一个：换 agent 不该顺带换工作目录，那只会让人找不到上次的文件。
    static var agentWorkspace: String {
        get { UserDefaults.standard.string(forKey: agentWorkspaceKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: agentWorkspaceKey)
            NotificationCenter.default.post(name: .sprigProvidersDidChange, object: nil)
        }
    }

    static var acpReady: Bool {
        !acpCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 没填工作目录时用这个。和知识库的 repository 并列，agent 的文件不要写进卡片库。
    static var defaultAgentWorkspace: String {
        sprigDirectory.appendingPathComponent("workspaces", isDirectory: true).path
    }

    static func workspacePath(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = ((trimmed.isEmpty ? defaultAgentWorkspace : trimmed) as NSString).expandingTildeInPath
        if trimmed.isEmpty {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        return path
    }

    static var acpWorkspacePath: String {
        workspacePath(for: agentWorkspace)
    }

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
        if usesAgent { usesAgent = false }
        activeProviderID = id
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
                return UserDefaults.standard.string(forKey: tavilyAPIKeyKey) ?? ""
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

    // MARK: - 免费模型（智谱）

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

            // 只有 OpenAI 兼容能这样探活。智谱的免费型号不在 /models 里，
            // 逐个探会把额度打光；Ollama 的模型就在本机，不存在调不通。
            var keep = models
            let isZhipu = config.baseURL.lowercased().contains("bigmodel")
            if config.kind == .openAICompatible && !isZhipu {
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
        case .openAICompatible:
            // 智谱的 /models 只返回付费型号（glm-4.5 ~ glm-5.3），
            // 真正免费的 glm-4.7-flash 不在里面。硬编码，别让同步把用户切到要钱的模型。
            if config.baseURL.lowercased().contains("bigmodel") {
                return ["glm-4.7-flash"]
            }
            let base = URL(string: config.baseURL)
                ?? URL(string: ProviderConfig.Kind.openAICompatible.defaultBaseURL)!
            let options = await OpenAICompatibleProvider.modelOptions(baseURL: base,
                                                                     apiKey: config.apiKey)
            return options.map(\.id)
        }
    }

    // MARK: - 知识库目录

    /// ~/Documents/Sprig。知识库和工作区都放在它下面。
    private static var sprigDirectory: URL {
        documentsDirectory.appendingPathComponent(AppInfo.englishName, isDirectory: true)
    }

    /// 知识库（卡片 JSON）所在目录，默认 ~/Documents/Sprig/repository
    static var defaultCardsDirectory: URL {
        sprigDirectory.appendingPathComponent("repository", isDirectory: true)
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

    /// 没填工作目录时，启动就建好默认目录，免得第一次提问才发现文件夹不存在。
    static func prepareAgentWorkspace() {
        guard agentWorkspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: defaultAgentWorkspace, withIntermediateDirectories: true)
    }
}
