import XCTest
@testable import SprigCore

final class AcpPresetsTests: XCTestCase {
    func testPresetsCoverTheCommonAgents() {
        let presets = AcpAgentPresets.builtin()
        let ids = Set(presets.map(\.id))
        for expected in ["codebuddy", "claude", "codex", "gemini", "opencode", "cursor", "qwen"] {
            XCTAssertTrue(ids.contains(expected), "缺少预设 \(expected)")
        }
        XCTAssertEqual(presets.first(where: { $0.id == "codebuddy" })?.command, "codebuddy --acp")
    }

    /// 下拉里同一份命令出现两次会很困惑，命令必须唯一。
    func testPresetCommandsAreUnique() {
        let commands = AcpAgentPresets.builtin().map(\.command)
        XCTAssertEqual(Set(commands).count, commands.count)
    }

    func testEveryPresetCarriesANameAndNote() {
        for preset in AcpAgentPresets.builtin() {
            XCTAssertFalse(preset.name.isEmpty)
            XCTAssertFalse(preset.note.isEmpty)
            XCTAssertFalse(preset.command.isEmpty)
        }
    }

    /// 本机 WorkBuddy 存在时它要排第一：那是唯一开箱即用的一条。
    func testWorkBuddyComesFirstWhenPresent() {
        guard AcpAgentPresets.workBuddyCLI() != nil else {
            return // 没装 WorkBuddy 的机器上不要求这条
        }
        let presets = AcpAgentPresets.builtin()
        XCTAssertEqual(presets.first?.id, "workbuddy")
        XCTAssertTrue(presets.first?.command.hasSuffix(" --acp") ?? false)
    }
}
