import XCTest
@testable import SprigCore

/// 上下文预算以前是写死的两套（本地 2400 / 云端 12000），
/// 云端那套对 1M 窗口的模型太保守。这些测试钉住「按窗口算」和「按句子截」的行为。
final class ContextPolicyTests: XCTestCase {
    // MARK: - 动态预算

    func testHugeWindowCapsAtThirtyThousand() {
        let policy = ContextAssembler.Policy.dynamic(contextTokens: 1_048_576, isLocal: false)
        XCTAssertEqual(policy.totalBudget, 30_000)
        XCTAssertEqual(policy.currentLimit, 15_000)
    }

    func testMidWindowUsesOneThird() {
        let policy = ContextAssembler.Policy.dynamic(contextTokens: 32_768, isLocal: false)
        XCTAssertEqual(policy.totalBudget, 10_922)   // 32768 / 3
    }

    func testTinyWindowFallsBackToFloor() {
        let policy = ContextAssembler.Policy.dynamic(contextTokens: 8_000, isLocal: false)
        XCTAssertEqual(policy.totalBudget, 4_000)
    }

    func testUnknownWindowFallsBackToCloud() {
        let policy = ContextAssembler.Policy.dynamic(contextTokens: nil, isLocal: false)
        XCTAssertEqual(policy.totalBudget, ContextAssembler.Policy.cloud.totalBudget)
    }

    /// 本地模型窗口再大也按紧的来：9B 级模型喂太长质量会崩
    func testLocalIgnoresWindow() {
        let policy = ContextAssembler.Policy.dynamic(contextTokens: 1_048_576, isLocal: true)
        XCTAssertEqual(policy.totalBudget, ContextAssembler.Policy.local.totalBudget)
    }

    func testToolReserveIsCarriedThrough() {
        let policy = ContextAssembler.Policy.dynamic(contextTokens: 128_000,
                                                     isLocal: false,
                                                     toolReserve: 3_000)
        XCTAssertEqual(policy.toolReserve, 3_000)
    }

    // MARK: - 预留会挤掉祖先

    private func makePath(ancestors: Int, answerLength: Int) -> [ContextAssembler.Node] {
        var path: [ContextAssembler.Node] = []
        for index in 0..<ancestors {
            path.append(.init(title: "祖先\(index)",
                              question: "问题\(index)",
                              answer: String(repeating: "答", count: answerLength)))
        }
        path.append(.init(title: "当前",
                          question: "当前问题",
                          answer: String(repeating: "现", count: answerLength)))
        return path
    }

    func testToolReserveShrinksAncestorContent() {
        let path = makePath(ancestors: 6, answerLength: 2_000)
        var withoutReserve = ContextAssembler.Policy.cloud
        withoutReserve.totalBudget = 12_000
        var withReserve = withoutReserve
        withReserve.toolReserve = 6_000

        let lean = ContextAssembler.context(path: path, policy: withoutReserve)
        let reserved = ContextAssembler.context(path: path, policy: withReserve)

        XCTAssertLessThan(reserved.count, lean.count, "预留了搜索空间，祖先就该少塞")
    }

    // MARK: - 按句子边界截断

    func testTruncateKeepsSentenceBoundary() {
        // 每句 10 字，第 6 句结束时刚好 60 字
        let text = String(repeating: "这是一个句子。", count: 20)
        let result = ContextAssembler.truncate(text, limit: 65)

        XCTAssertTrue(result.hasSuffix("…"))
        XCTAssertFalse(result.contains("这是一个句…"), "不该切在句子中间")
    }

    func testTruncatePrefersParagraphBreak() {
        let text = String(repeating: "甲", count: 80) + "\n" + String(repeating: "乙", count: 80)
        let result = ContextAssembler.truncate(text, limit: 100)

        XCTAssertTrue(result.hasSuffix("…"))
        XCTAssertFalse(result.contains("乙"), "有换行就该切在换行处")
    }

    /// 整段没有标点时不能返回空，退回硬截
    func testTruncateFallsBackToHardCut() {
        let text = String(repeating: "字", count: 200)
        let result = ContextAssembler.truncate(text, limit: 50)

        XCTAssertEqual(result.count, 51)   // 50 字 + 省略号
        XCTAssertTrue(result.hasSuffix("…"))
    }

    func testTruncateLeavesShortTextAlone() {
        XCTAssertEqual(ContextAssembler.truncate("很短", limit: 100), "很短")
    }
}
