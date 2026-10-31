import XCTest
@testable import SprigCore

final class CardMarkdownTests: XCTestCase {
    func testOneFilePerRootIncludesDescendants() {
        let root = AnswerCard(title: "RAG", question: "什么是 RAG？它解决了什么问题？", answer: "结合检索与生成，缓解⟦幻觉⟧。")
        let child = AnswerCard(parentID: root.id,
                               title: "幻觉",
                               question: "解释「幻觉」",
                               answer: "这里指模型编造事实。",
                               selectedText: "幻觉",
                               createdAt: root.createdAt.addingTimeInterval(1))
        let grandchild = AnswerCard(parentID: child.id,
                                    title: "虚构引用",
                                    question: "举一个例子",
                                    answer: "编造一篇不存在的论文。",
                                    createdAt: root.createdAt.addingTimeInterval(2))
        let other = AnswerCard(title: "另一题", question: "另一题", answer: "别的树。", createdAt: root.createdAt.addingTimeInterval(10))

        let files = CardMarkdown.files(from: [grandchild, other, child, root])
        XCTAssertEqual(files.map(\.name), ["RAG.md", "另一题.md"])

        let body = files[0].body
        XCTAssertTrue(body.hasPrefix("<!-- sprig:root \(root.id.uuidString) -->"))
        XCTAssertTrue(body.contains("# RAG"))
        XCTAssertTrue(body.contains("什么是 RAG？它解决了什么问题？"))
        XCTAssertTrue(body.contains("结合检索与生成，缓解幻觉。"))
        XCTAssertFalse(body.contains("⟦"))
        XCTAssertTrue(body.contains("## 幻觉"))
        XCTAssertTrue(body.contains("> 选中：幻觉"))
        XCTAssertTrue(body.contains("### 虚构引用"))
        XCTAssertFalse(body.contains("另一题"))
    }

    func testDuplicateRootTitlesGetAStableSuffix() {
        let earlier = AnswerCard(title: "RAG", question: "第一棵", createdAt: Date(timeIntervalSince1970: 1))
        let later = AnswerCard(title: "RAG", question: "第二棵", createdAt: Date(timeIntervalSince1970: 2))
        let files = CardMarkdown.files(from: [later, earlier])
        XCTAssertEqual(files.map(\.name), ["RAG.md", "RAG-\(later.id.uuidString.prefix(8)).md"])
    }

    func testSyncWritesTreesAndRemovesOnlyGeneratedFiles() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-md-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let note = directory.appendingPathComponent("我的笔记.md")
        try "不要删".write(to: note, atomically: true, encoding: .utf8)

        let root = AnswerCard(title: "旧标题", question: "问题")
        try CardMarkdown.sync([root], in: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("旧标题.md").path))

        let renamed = AnswerCard(id: root.id, title: "新标题", question: "问题", createdAt: root.createdAt)
        try CardMarkdown.sync([renamed], in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("旧标题.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("新标题.md").path))
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "不要删")

        try? FileManager.default.removeItem(at: directory)
    }

    /// 图表块导出成表格：知识库里不该出现图表 JSON
    func testChartBlockBecomesTable() {
        let text = """
        营收走势：

        ```sprig-chart
        {"type":"bar","title":"季度营收","labels":["Q1","Q2"],"values":[12,30]}
        ```
        """
        let expanded = CardMarkdown.expandChartBlocks(in: text)
        XCTAssertTrue(expanded.contains("**季度营收**"))
        XCTAssertTrue(expanded.contains("| 项目 | 数值 |"))
        XCTAssertTrue(expanded.contains("| Q1 | 12 |"))
        XCTAssertTrue(expanded.contains("| Q2 | 30 |"))
        XCTAssertFalse(expanded.contains("sprig-chart"))
        XCTAssertFalse(expanded.contains("\"labels\""))
    }

    /// 解析不了的图表 JSON 原样保留（当代码块），不要吞内容
    func testBrokenChartFallsBackToCode() {
        let text = "```sprig-chart\n{不是 JSON}\n```"
        let expanded = CardMarkdown.expandChartBlocks(in: text)
        XCTAssertTrue(expanded.contains("{不是 JSON}"))
    }

    /// HTML 图块：图片在就引用图片，不在就把标签转义成代码块
    func testHtmlBlockReferencesImageWhenAvailable() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-html-\(UUID().uuidString)", isDirectory: true)
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        let html = "<svg><rect/></svg>"
        let name = HtmlAsset.name(for: html)
        try Data("png".utf8).write(to: assets.appendingPathComponent(name))

        let text = "图示：\n\n```html\n\(html)\n```"
        let withImage = CardMarkdown.expandHtmlBlocks(in: text, assetsDirectory: directory)
        XCTAssertTrue(withImage.contains("![图示](assets/\(name))"))
        XCTAssertFalse(withImage.contains("<svg>"))

        let withoutImage = CardMarkdown.expandHtmlBlocks(in: text, assetsDirectory: nil)
        XCTAssertTrue(withoutImage.contains("```html"))
        XCTAssertTrue(withoutImage.contains("&lt;svg&gt;&lt;rect/&gt;&lt;/svg&gt;"))

        try? FileManager.default.removeItem(at: directory)
    }

    /// 同样的 HTML 只对应一个文件名（内容哈希稳定）
    func testHtmlAssetNameIsStable() {
        XCTAssertEqual(HtmlAsset.name(for: "<div/>"), HtmlAsset.name(for: "<div/>"))
        XCTAssertNotEqual(HtmlAsset.name(for: "<div/>"), HtmlAsset.name(for: "<span/>"))
    }

    /// 最基本的落盘路径：写成 `.cards.json`，同时产出一份 Markdown。
    func testStoreWritesHiddenJSONAndMarkdown() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = directory.appendingPathComponent(CardStore.fileName)

        let store = CardStore(fileURL: json)
        await store.upsert(AnswerCard(title: "RAG", question: "什么是 RAG？", answer: "检索增强。"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
        let markdown = try String(contentsOf: directory.appendingPathComponent("RAG.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("什么是 RAG？"))

        let reloaded = CardStore(fileURL: json)
        let titles = await reloaded.all()
        XCTAssertEqual(titles.map(\.title), ["RAG"])

        try? FileManager.default.removeItem(at: directory)
    }
}
