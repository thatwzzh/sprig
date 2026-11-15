import XCTest
@testable import SprigCore

final class SelectionTextExcerptTests: XCTestCase {
    func testExcerptLocatesParagraphAroundSelection() {
        var paragraphs: [String] = []
        for index in 0..<10 {
            paragraphs.append("段落\(index)：" + String(repeating: "字", count: 120) + " 标记\(index)")
        }
        paragraphs[5] = "段落5：这里才是选区所在的段落，RAG 会缓解模型的幻觉问题。"
        let text = paragraphs.joined(separator: "\n\n")
        let excerpt = SelectionTextExcerpt.excerpt(from: text, selection: "幻觉", limit: 500)
        XCTAssertNotNil(excerpt)
        XCTAssertTrue(excerpt!.contains("幻觉"))
        XCTAssertTrue(excerpt!.contains("选区所在的段落"))
        XCTAssertFalse(excerpt!.contains("段落0"), "不该把离得很远的段落带上")
        XCTAssertLessThanOrEqual(excerpt!.count, 500)
    }

    func testExcerptRejectsTextWithoutSelection() {
        let css = ".subs p { margin: 0; color: var(--ink2); }"
        XCTAssertNil(SelectionTextExcerpt.excerpt(from: css, selection: "供应商", limit: 500))
    }

    func testExcerptNormalizesCRLFAndCrossLineSelection() {
        let text = "第一段\r\n\r\n选区在第二行\r\n继续\r\n\r\n最后一段"
        let excerpt = SelectionTextExcerpt.excerpt(from: text,
                                                    selection: "选区在第二行 继续",
                                                    limit: 500)
        XCTAssertNotNil(excerpt)
        XCTAssertTrue(excerpt!.contains("选区在第二行"))
        XCTAssertFalse(excerpt!.contains("\r"))
    }

    func testDocumentContextHandlesCRLFFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-crlf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("crlf.md")
        let text = "# 标题\r\n\r\n## 检索\r\n\r\n这里讨论召回率。\r\n"
        try text.write(to: url, atomically: true, encoding: .utf8)

        let result = DocumentContext.context(filePath: url.path, selection: "召回率", limit: 500)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.excerpt.contains("召回率"))
        XCTAssertEqual(result!.source.headingPath, ["标题", "检索"])
    }

    func testDocumentContextStripsFrontmatterAndComments() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-md-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let text = """
        ---
        title: RAG 笔记
        tags: [ai]
        ---

        # 标题

        <!-- 这段是注释噪音 -->

        这里解释幻觉问题。
        """
        let url = directory.appendingPathComponent("note.md")
        try text.write(to: url, atomically: true, encoding: .utf8)

        let result = DocumentContext.context(filePath: url.path, selection: "幻觉", limit: 500)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.excerpt.contains("幻觉"))
        XCTAssertFalse(result!.excerpt.contains("title: RAG 笔记"))
        XCTAssertFalse(result!.excerpt.contains("注释噪音"))
    }

    func testWebVisibleTextSeparatesTableCellsAndDropsButtons() {
        let html = """
        <table><tr><td>召回率</td><td>0.8</td></tr></table>
        <button>下载 Mac 版</button>
        <p>正文保留。</p>
        """
        let text = WebPageContext.visibleText(fromHTML: html)
        XCTAssertTrue(text.contains("召回率"))
        XCTAssertTrue(text.contains("0.8"))
        XCTAssertFalse(text.contains("下载 Mac 版"))
        XCTAssertTrue(text.contains("正文保留"))
    }
}
