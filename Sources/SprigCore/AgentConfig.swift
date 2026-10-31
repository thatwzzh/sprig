import Foundation

/// 一条 agent 配置。自定义和自动检测出来的用的是同一种结构。
public struct AgentConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    /// 会话里要用的模型 id。nil 表示不干预，用 agent 自己的默认。
    public var modelID: String?
    /// 模型显示名，只用于界面
    public var modelLabel: String?
    /// 这个模型的输入窗口（token），上下文预算按它算
    public var modelMaxInput: Int?
    /// 思考强度（agent 的 thought_level / reasoning_effort），nil 表示不干预
    public var thoughtLevel: String?
    /// 自动检测出来的记来源，方便「重新检测」时去重；自定义的为 nil
    public var presetID: String?

    public init(id: UUID = UUID(),
                name: String,
                command: String,
                modelID: String? = nil,
                modelLabel: String? = nil,
                modelMaxInput: Int? = nil,
                thoughtLevel: String? = nil,
                presetID: String? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.modelID = modelID
        self.modelLabel = modelLabel
        self.modelMaxInput = modelMaxInput
        self.thoughtLevel = thoughtLevel
        self.presetID = presetID
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? command : trimmed
    }
}

/// 扫本机已经装了什么，给设置页直接列出来。
public enum AgentDetector {
    /// 检测顺序：先 WorkBuddy 自带的那条（开箱即用），再按预设顺序。
    public static func detect() -> [AgentConfig] {
        detected().map { preset in
            AgentConfig(name: preset.name, command: preset.command, presetID: preset.id)
        }
    }

    /// 命中判定的三种情况：可执行文件在 PATH 上、WorkBuddy 自带 CLI 存在、
    /// npx 缓存里已经有这个包（跑过一次就不用再下）。
    static func detected() -> [AcpAgentPreset] {
        AcpAgentPresets.builtin().filter { preset in
            if let cached = preset.npxPackage { return npxCacheContains(cached) }
            return AcpEnvironment.resolveProgram(in: preset.command) != nil
        }
    }

    static func npxCacheContains(_ package: String) -> Bool {
        let root = (NSHomeDirectory() as NSString).appendingPathComponent(".npm/_npx")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return false }
        for entry in entries {
            let manifest = (root as NSString)
                .appendingPathComponent("\(entry)/node_modules/\(package)/package.json")
            if FileManager.default.fileExists(atPath: manifest) { return true }
        }
        return false
    }
}
