import XCTest
@testable import SprigCore

final class DeepContextTests: XCTestCase {
    func testShouldSummarizeOnlyForLargeContext() {
        let short = String(repeating: "召回率。", count: 100)   // ~400 字
        XCTAssertFalse(DeepContextComposer.shouldSummarize(short))
        let long = String(repeating: "召回率与精确率是检索系统的两个核心指标，需要结合上下文一起理解。", count: 100)
        XCTAssertTrue(DeepContextComposer.shouldSummarize(long))
    }

    func testComposeKeepsLocalExcerptAndSummaryMarker() {
        let context = DeepContextComposer.compose(
            localExcerpt: "选区所在段落：这里讨论召回率。",
            summary: "摘要：文档主要讨论检索指标和评估方法。",
            fallback: "原始长上下文",
            limit: 1_500)
        XCTAssertNotNil(context)
        XCTAssertTrue(context!.contains("选区所在段落"))
        XCTAssertTrue(context!.contains("【长上下文摘要】"))
        XCTAssertTrue(context!.contains("检索指标"))
        XCTAssertFalse(context!.contains("摘要："))
        XCTAssertFalse(context!.contains("原始长上下文"))
    }

    func testComposeFallsBackWhenSummaryMissing() {
        let context = DeepContextComposer.compose(
            localExcerpt: "局部段落",
            summary: nil,
            fallback: "原始上下文：召回率的定义……",
            limit: 500)
        XCTAssertEqual(context, "原始上下文：召回率的定义……")
    }

    func testComposeFallsBackToLocalWhenNoFallback() {
        let context = DeepContextComposer.compose(
            localExcerpt: "局部段落内容",
            summary: nil,
            fallback: nil,
            limit: 500)
        XCTAssertEqual(context, "局部段落内容")
    }

    func testSummaryIsTruncatedToBudget() {
        let longSummary = String(repeating: "这是一段很长的摘要。", count: 200)
        let cleaned = DeepContextComposer.cleanSummary(longSummary, maxChars: 200)
        XCTAssertNotNil(cleaned)
        XCTAssertLessThanOrEqual(cleaned!.count, 201)
    }

    func testExtractiveSummaryKeepsRelevantSentences() {
        let context = "无关内容。检索阶段通常看召回率，召回率衡量找回了多少相关片段。"
            + "生成阶段把检索结果交给模型。精确率衡量返回结果里有多少是相关的。"
        let summary = DeepContextComposer.extractiveSummary(context: context,
                                                            selection: "召回率",
                                                            maxChars: 200)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("召回率"))
        XCTAssertLessThanOrEqual(summary!.count, 220)
    }

    func testExtractiveSummaryReturnsNilForUnrelatedText() {
        XCTAssertNil(DeepContextComposer.extractiveSummary(context: "完全无关的一句话。",
                                                           selection: "召回率",
                                                           maxChars: 200))
    }

    func testDeepPolicyExpandsLocalContextBudget() {
        let normal = SelectionContextAssembler.Policy.dynamic(isLocal: true,
                                                              contextTokens: nil,
                                                              selectionCap: 500)
        let deep = SelectionContextAssembler.Policy.dynamic(isLocal: true,
                                                            contextTokens: nil,
                                                            selectionCap: 500,
                                                            deepContext: true)
        XCTAssertGreaterThan(deep.contextLimit, normal.contextLimit)
    }
}
