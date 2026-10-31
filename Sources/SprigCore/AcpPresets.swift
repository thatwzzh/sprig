import Foundation

/// 一个可以直接填进「Agent 启动命令」的预设。
///
/// 清单照着 dsh-ntr 的 `AGENT_PRESETS`（`src/bridge.ts`）抄的，只留启动命令这一层：
/// 谁是完整变体、谁要 `--serve`，由 `AcpEnvironment.codebuddyLaunchAdjustment` 在启动时补，
/// 预设里写的就是用户自己会在终端敲的那条。
public struct AcpAgentPreset: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let command: String
    /// 填进命令栏后显示在状态行里的一句话
    public let note: String
    /// 走 npx 的包名：检测时不能只看 PATH 上有没有 npx，要看这个包有没有被下过
    public let npxPackage: String?

    public init(id: String, name: String, command: String, note: String, npxPackage: String? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.note = note
        self.npxPackage = npxPackage
    }
}

public enum AcpAgentPresets {
    /// 本机 WorkBuddy 自带的 CLI。它是 lite 变体，启动参数由 launch adjustment 补。
    public static func workBuddyCLI() -> String? {
        let relative = "Contents/Resources/app.asar.unpacked/cli/bin/codebuddy"
        let candidates = [
            ("/Applications/WorkBuddy.app" as NSString).appendingPathComponent(relative),
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications/WorkBuddy.app/\(relative)"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 内置清单。WorkBuddy 排第一，因为这台机器上它就绪即用。
    public static func builtin() -> [AcpAgentPreset] {
        var presets: [AcpAgentPreset] = []
        if let cli = workBuddyCLI() {
            presets.append(AcpAgentPreset(
                id: "workbuddy",
                name: "WorkBuddy",
                command: "\(cli) --acp",
                note: "WorkBuddy 自带的 CodeBuddy CLI，登录态单独一份，不影响桌面端"))
        }
        presets.append(contentsOf: [
            AcpAgentPreset(id: "codebuddy",
                           name: "CodeBuddy Code",
                           command: "codebuddy --acp",
                           note: "独立安装的 CodeBuddy Code CLI"),
            AcpAgentPreset(id: "claude",
                           name: "Claude Code",
                           command: "npx -y @agentclientprotocol/claude-agent-acp",
                           note: "Claude Agent SDK 的 ACP 适配器；先在终端登录过一次 Claude Code",
                           npxPackage: "@agentclientprotocol/claude-agent-acp"),
            AcpAgentPreset(id: "codex",
                           name: "Codex",
                           command: "npx -y @agentclientprotocol/codex-acp",
                           note: "OpenAI Codex 的 ACP 适配器；先在终端 codex login 一次",
                           npxPackage: "@agentclientprotocol/codex-acp"),
            AcpAgentPreset(id: "gemini",
                           name: "Gemini CLI",
                           command: "gemini --experimental-acp",
                           note: "Google Gemini CLI"),
            AcpAgentPreset(id: "opencode",
                           name: "OpenCode",
                           command: "opencode acp",
                           note: "OpenCode"),
            AcpAgentPreset(id: "cursor",
                           name: "Cursor CLI",
                           command: "agent acp",
                           note: "Cursor CLI（旧别名 cursor-agent acp）"),
            AcpAgentPreset(id: "qwen",
                           name: "Qwen Code",
                           command: "qwen --experimental-acp",
                           note: "Qwen Code"),
            AcpAgentPreset(id: "kiro",
                           name: "Kiro",
                           command: "kiro-cli acp",
                           note: "Kiro CLI"),
            AcpAgentPreset(id: "qoder",
                           name: "Qoder",
                           command: "qodercli --acp",
                           note: "Qoder CLI"),
            AcpAgentPreset(id: "qoder-cn",
                           name: "Qoder CN",
                           command: "qoderclicn --acp",
                           note: "Qoder CLI 国内版"),
            AcpAgentPreset(id: "omp",
                           name: "Oh My Pi",
                           command: "omp acp",
                           note: "基于 pi 的编码 agent"),
            AcpAgentPreset(id: "pi",
                           name: "Pi Coding Agent",
                           command: "pi-acp",
                           note: "自带 ACP 桥接"),
        ])
        return presets
    }
}
