import Foundation
import SprigCore

enum Settings {
    private static let modelKey = "ollamaModel"
    private static let baseURLKey = "ollamaBaseURL"
    private static let cardsDirectoryKey = "cardsDirectory"
    private static let migratedKey = "didMigrateFromLegacyBundle"

    static let defaultModel = "qwen3:4b-instruct"

    static var model: String {
        get {
            // 便于 --headless 调试时临时换模型：SPRIG_MODEL=qwen3:4b-instruct
            let env = ProcessInfo.processInfo.environment
            if let override = env["SPRIG_MODEL"] ?? env["CONCEPTLENS_MODEL"], !override.isEmpty {
                return override
            }
            return UserDefaults.standard.string(forKey: modelKey) ?? defaultModel
        }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    static var baseURL: URL {
        let raw = UserDefaults.standard.string(forKey: baseURLKey) ?? "http://127.0.0.1:11434"
        return URL(string: raw) ?? URL(string: "http://127.0.0.1:11434")!
    }

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

    static var provider: LLMProvider {
        OllamaProvider(baseURL: baseURL, model: model)
    }

    /// 包名从 com.catking.conceptlens 换成 com.catking.sprig 后，UserDefaults 域也跟着换了，
    /// 这里把旧的模型 / 地址 / 目录 / 已录制的快捷键搬过来，避免升级后设置被重置。
    /// 必须在读取任何设置、注册快捷键之前调用。
    static func migrateLegacyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)

        guard let legacy = UserDefaults(suiteName: AppInfo.legacyBundleIdentifier) else { return }
        for (key, value) in legacy.dictionaryRepresentation() where isMigratableKey(key) {
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
        }
    }

    private static func isMigratableKey(_ key: String) -> Bool {
        if key.hasPrefix("KeyboardShortcuts") { return true }
        return key == modelKey || key == baseURLKey || key == cardsDirectoryKey
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
