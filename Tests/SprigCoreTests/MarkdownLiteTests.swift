import XCTest
@testable import SprigCore

final class MarkdownLiteTests: XCTestCase {
    func testHeadingsListsAndParagraphs() {
        let blocks = MarkdownLite.parse("""
        # 标题

        正文一段
        第二行

        - 项目一
        - 项目二
        1. 有序
        > 引用
        """)
        XCTAssertEqual(blocks.map(\.kind), [
            .heading(1), .paragraph, .bullet, .bullet, .ordered("1."), .quote,
        ])
        // 连续两行正文合成一段，不额外吃段间距
        XCTAssertEqual(blocks[1].plainText, "正文一段\n第二行")
        XCTAssertEqual(blocks[2].plainText, "项目一")
        XCTAssertEqual(blocks[4].plainText, "有序")
        XCTAssertEqual(blocks[5].plainText, "引用")
    }

    /// 「#标题」不是标题（缺空格），别把正文吃掉
    func testHashWithoutSpaceIsText() {
        let blocks = MarkdownLite.parse("#不是标题")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph])
        XCTAssertEqual(blocks[0].plainText, "#不是标题")
    }

    func testCodeBlockKeepsMarkdown() {
        let blocks = MarkdownLite.parse("""
        ```swift
        let a = 1 * 2
        # 不是标题
        ```
        后面的话
        """)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].kind, .code("swift"))
        XCTAssertEqual(blocks[0].plainText, "let a = 1 * 2\n# 不是标题")
        XCTAssertEqual(blocks[1].plainText, "后面的话")
    }

    func testInlineStylesAndTerms() {
        let blocks = MarkdownLite.parse("这是 **粗体**、*斜体* 和 `代码`，还有 ⟦幻觉⟧。")
        XCTAssertEqual(blocks[0].inlines, [
            .text("这是 "),
            .bold("粗体"),
            .text("、"),
            .italic("斜体"),
            .text(" 和 "),
            .code("代码"),
            .text("，还有 "),
            .term("幻觉"),
            .text("。"),
        ])
    }

    /// 粗体里裹术语：⟦⟧ 要被吃掉，术语本身保留可点
    func testTermInsideBold() {
        let blocks = MarkdownLite.parse("- **多路复用（⟦Multiplexing⟧）**：并行传输")
        guard case .bullet = blocks[0].kind else { return XCTFail("应该是列表") }
        XCTAssertEqual(blocks[0].inlines, [
            .bold("多路复用（"),
            .term("Multiplexing"),
            .bold("）"),
            .text("：并行传输"),
        ])
        XCTAssertFalse(blocks[0].plainText.contains("⟦"))
    }

    func testGfmTable() {
        let blocks = MarkdownLite.parse("""
        对比一下：

        | 方案 | 延迟 | 成本 |
        | --- | :--: | ---: |
        | 本地 | 20ms | 0 |
        | 云端 40ms | 0.01 |

        结论如上。
        """)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].kind, .paragraph)
        XCTAssertEqual(blocks[1].kind, .table(header: ["方案", "延迟", "成本"],
                                              rows: [["本地", "20ms", "0"], ["云端 40ms", "0.01"]]))
        XCTAssertEqual(blocks[2].kind, .paragraph)
    }

    func testChartBlockParsesToSpec() {
        let blocks = MarkdownLite.parse("""
        看这张图：

        ```sprig-chart
        {"type":"line","title":"延迟","labels":["1月","2月"],"values":[120,96]}
        ```
        """)
        guard case .chart(let spec) = blocks[1].kind else { return XCTFail("应该解析成图表") }
        XCTAssertEqual(spec.kind, .line)
        XCTAssertEqual(spec.title, "延迟")
        XCTAssertEqual(spec.labels, ["1月", "2月"])
        XCTAssertEqual(spec.values, [120, 96])
    }

    /// 图表 JSON 坏了就退回普通代码块，不能把内容吞掉
    func testBrokenChartStaysCodeBlock() {
        let blocks = MarkdownLite.parse("""
        ```sprig-chart
        {"labels":["a"]}
        ```
        """)
        guard case .code(let language) = blocks[0].kind else { return XCTFail("应该还是代码块") }
        XCTAssertEqual(language, "sprig-chart")
        XCTAssertTrue(blocks[0].plainText.contains("labels"))
    }

    /// 单元格里的术语标记和行内代码标记都要去掉（表格是纯文本渲染）
    func testTableCellStripsInlineMarkers() {
        let blocks = MarkdownLite.parse("""
        | 项 | 值 |
        | --- | --- |
        | ⟦幻觉⟧ | `http://x/v1` |
        """)
        guard case .table(_, let rows) = blocks[0].kind else { return XCTFail("应该是表格") }
        XCTAssertEqual(rows, [["幻觉", "http://x/v1"]])
    }

    /// 只有一根竖线不算表格（缺分隔行）
    func testPipeWithoutSeparatorStaysParagraph() {
        let blocks = MarkdownLite.parse("a | b 只是普通文本")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph])
    }

    /// 未闭合的标记保持原样，不要吞掉后面的字
    func testUnclosedMarkersStayLiteral() {
        let blocks = MarkdownLite.parse("这里有 **没闭合")
        XCTAssertEqual(blocks[0].plainText, "这里有 **没闭合")
        XCTAssertEqual(blocks[0].inlines, [.text("这里有 **没闭合")])
    }
}
