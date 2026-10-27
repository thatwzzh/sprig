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

    static let defaultModel = ProviderConfig.Kind.ollama.defaultModel

    // MARK: - 模型接入

    /// 全部接入配置。没存过时给出内置的 Gemini + Ollama 两条。
    static var providerConfigs: [ProviderConfig] {
        get {
            if let data = UserDefaults.standard.data(forKey: providersKey),
               let decoded = try? JSONDecoder().decode([ProviderConfig].self, from: data),
               !decoded.isEmpty {
                return decoded
            }
            return ProviderConfig.builtins(ollamaModel: legacyModel, ollamaBaseURL: legacyBaseURL)
        }
        set {
            let value = newValue.isEmpty ? ProviderConfig.builtins(ollamaModel: legacyModel, ollamaBaseURL: legacyBaseURL) : newValue
            guard let data = try? JSONEncoder().encode(value) else { return }
            UserDefaults.standard.set(data, forKey: providersKey)
            NotificationCenter.default.post(name: .sprigProvidersDidChange, object: nil)
        }
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
        let env = ProcessInfo.processInfo.environment
        if let override = env["SPRIG_MODEL"] ?? env["CONCEPTLENS_MODEL"], !override.isEmpty {
            config.model = override
        }
        return config
    }

    static var provider: LLMProvider {
        activeConfig.makeProvider()
    }

    static func selectProvider(id: UUID) {
        guard providerConfigs.contains(where: { $0.id == id }) else { return }
        activeProviderID = id
    }

    /// 把探测到的 Ollama 模型写进内置 Ollama 项。
    /// 只在用户没手动改过（仍是默认模型名）时生效，避免覆盖用户设置。
    static func adoptDetectedOllamaModels(_ models: [String]) {
        guard let preferred = models.first(where: { $0.hasPrefix("qwen3") }) ?? models.first else { return }
        var configs = providerConfigs
        guard let index = configs.firstIndex(where: { $0.kind == .ollama }),
              configs[index].model == ProviderConfig.Kind.ollama.defaultModel else { return }
        configs[index].model = preferred
        providerConfigs = configs
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
