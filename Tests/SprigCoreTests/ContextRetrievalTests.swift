import XCTest
@testable import SprigCore

final class ContextRetrievalTests: XCTestCase {
    func testRetrievalAddsRelevantSectionAndKeepsLabels() {
        let markdown = """
        # 概览

        这篇笔记讲 RAG。

        # 检索

        召回率衡量检索阶段找回了多少相关片段。

        # 生成

        生成阶段把检索结果交给模型。

        # 附录

        召回率 = 命中的相关片段 / 全部相关片段。
        """
        let sections = DocumentContext.markdownSections(in: markdown)
        let excerpt = ContextRetrieval.excerpt(sections: sections,
                                               selection: "召回率",
                                               limit: 800)
        XCTAssertNotNil(excerpt)
        XCTAssertTrue(excerpt!.contains("【检索】"))
        XCTAssertTrue(excerpt!.contains("召回率衡量"))
        XCTAssertTrue(excerpt!.contains("【附录】"), "同关键词的其他章节应被带进来")
        XCTAssertFalse(excerpt!.contains("生成阶段"), "无关章节不该带")
        XCTAssertLessThanOrEqual(excerpt!.count, 800)
    }

    func testLongPrimarySectionDoesNotAddDistantSection() {
        let longBody = String(repeating: "前文内容。", count: 200)
            + "这里讨论召回率。"
            + String(repeating: "后续内容。", count: 200)
        let sections = [
            ContextSection(label: "主章节", text: longBody),
            ContextSection(label: "远处附录", text: "召回率的另一个定义。"),
        ]
        let excerpt = ContextRetrieval.excerpt(sections: sections,
                                               selection: "召回率",
                                               limit: 1200)
        XCTAssertNotNil(excerpt)
        XCTAssertTrue(excerpt!.contains("召回率"))
        XCTAssertFalse(excerpt!.contains("远处附录"), "主段落足够长时不该硬塞其他章节")
    }

    func testRetrievalDoesNotAddUnrelatedSections() {
        let markdown = """
        # A

        这里出现关键词。

        # B

        完全无关的内容。
        """
        let sections = DocumentContext.markdownSections(in: markdown)
        let excerpt = ContextRetrieval.excerpt(sections: sections,
                                               selection: "关键词",
                                               limit: 500)
        XCTAssertNotNil(excerpt)
        XCTAssertTrue(excerpt!.contains("关键词"))
        XCTAssertFalse(excerpt!.contains("完全无关"))
    }

    func testRetrievalReturnsNilWhenSelectionMissing() {
        let sections = [ContextSection(label: "页", text: "没有目标词")]
        XCTAssertNil(ContextRetrieval.excerpt(sections: sections, selection: "召回率", limit: 500))
    }

    func testQueryTermsIncludesCJKCigramsAndLatinWords() {
        let terms = ContextRetrieval.queryTerms(from: "RAG 的召回率 recall_rate")
        XCTAssertTrue(terms.contains("rag"))
        XCTAssertTrue(terms.contains("召回"))
        XCTAssertTrue(terms.contains("回率"))
        XCTAssertTrue(terms.contains("recall"))
        XCTAssertTrue(terms.contains("rate"))
    }

    func testTokenEstimatorIsReasonable() {
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
        let chinese = String(repeating: "召回率", count: 100)
        let chineseTokens = TokenEstimator.estimate(chinese)
        XCTAssertTrue((200...360).contains(chineseTokens), "300 个中文字不应被估成极端值：\(chineseTokens)")

        let english = String(repeating: "retrieval ", count: 100)
        let englishTokens = TokenEstimator.estimate(english)
        XCTAssertTrue((150...400).contains(englishTokens), "英文估算异常：\(englishTokens)")

        XCTAssertTrue(TokenEstimator.describe("召回率 511 字").contains("≈"))
    }
}
